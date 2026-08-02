//
//  MediaLoaderService.swift
//  EncameraCore
//
//  Created for separation of concerns refactoring
//

import Foundation
import Photos
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Result of loading a single media item from the photo library
public struct LoadedMediaItem {
    public let media: [CleartextMedia]
    public let metadata: EncryptedFileMetadata?
    public let assetIdentifier: String?
    
    public init(media: [CleartextMedia], metadata: EncryptedFileMetadata?, assetIdentifier: String?) {
        self.media = media
        self.metadata = metadata
        self.assetIdentifier = assetIdentifier
    }
}

/// Result of loading a batch of media from the photo library
public struct LoadedMediaBatch {
    public let media: [CleartextMedia]
    public let assetIdentifiers: [String]
    public let successfulLoads: Int
    public let failedLoads: Int
    
    public init(media: [CleartextMedia], assetIdentifiers: [String], successfulLoads: Int, failedLoads: Int) {
        self.media = media
        self.assetIdentifiers = assetIdentifiers
        self.successfulLoads = successfulLoads
        self.failedLoads = failedLoads
    }
}

/// Service responsible for loading media from the Photos library into temporary storage
/// This handles extraction of PHAssets and PHPickerResults into CleartextMedia objects
@MainActor
public class MediaLoaderService: DebugPrintable {
    
    // Cache directory check state to avoid hitting filesystem repeatedly
    private var tempDirectoryChecked = false
    
    /// Metadata extractor for extracting media metadata
    private let metadataExtractor = MediaMetadataExtractor()
    
    public init() {}
    
    // MARK: - Public API
    
    /// Loads media from an array of MediaSelectionResults
    /// Returns a batch with all successfully loaded media and statistics
    public func loadMedia(from results: [MediaSelectionResult]) async throws -> LoadedMediaBatch {
        try await ensureTempDirectoryExists()
        
        var allMedia: [CleartextMedia] = []
        var assetIdentifiers: [String] = []
        var successfulLoads = 0
        var failedLoads = 0
        
        for (index, result) in results.enumerated() {
            printDebug("📄 Processing result \(index + 1)/\(results.count)")
            
            do {
                let loaded = try await loadSingleMedia(from: result)
                
                allMedia.append(contentsOf: loaded.media)
                successfulLoads += 1
                
                if let assetId = loaded.assetIdentifier {
                    assetIdentifiers.append(assetId)
                }
                
            } catch {
                failedLoads += 1
                logMediaLoadError(error, for: result)
            }
        }
        
        printDebug("📈 Summary - Successful: \(successfulLoads), Failed: \(failedLoads), Total media: \(allMedia.count)")
        
        return LoadedMediaBatch(
            media: allMedia,
            assetIdentifiers: assetIdentifiers,
            successfulLoads: successfulLoads,
            failedLoads: failedLoads
        )
    }
    
    /// Loads media from a single MediaSelectionResult
    /// Returns the loaded media, metadata, and optional asset ID
    public func loadSingleMedia(from result: MediaSelectionResult) async throws -> LoadedMediaItem {
        try await ensureTempDirectoryExists()
        
        switch result {
        case .phAsset(let asset):
            let media = try await loadMediaFromAsset(asset)
            // Extract metadata from the PHAsset
            let metadata = await metadataExtractor.extractMetadata(from: asset)
            return LoadedMediaItem(media: media, metadata: metadata, assetIdentifier: asset.localIdentifier)
            
        case .phPickerResult(let pickerResult):
            let media = try await loadMediaAsync(result: pickerResult)
            // For PHPickerResult, we can only extract metadata from the file URL
            // Try to get PHAsset if available for richer metadata
            var metadata: EncryptedFileMetadata?
            if let assetId = pickerResult.assetIdentifier {
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
                if let asset = fetchResult.firstObject {
                    metadata = await metadataExtractor.extractMetadata(from: asset)
                }
            }
            // If we couldn't get PHAsset metadata, extract from the file URL
            if metadata == nil, let firstMedia = media.first, let url = firstMedia.url {
                metadata = await metadataExtractor.extractMetadata(from: url, mediaType: firstMedia.mediaType)
            }
            return LoadedMediaItem(media: media, metadata: metadata, assetIdentifier: pickerResult.assetIdentifier)
        }
    }
    
    /// Legacy method for backwards compatibility - returns tuple format
    public func loadSingleMediaTuple(from result: MediaSelectionResult) async throws -> (media: [CleartextMedia], assetId: String?) {
        let loaded = try await loadSingleMedia(from: result)
        return (loaded.media, loaded.assetIdentifier)
    }
    
    // MARK: - Private Implementation
    
    // MARK: - PHPickerResult Loading
    
    private func loadMediaAsync(result: PHPickerResult) async throws -> [CleartextMedia] {
        // Identify whether the item is a video or an image
        let isLivePhoto = result.itemProvider.canLoadObject(ofClass: PHLivePhoto.self)
        if isLivePhoto {
            return try await loadLivePhoto(result: result)
        } else {
            return [try await loadMedia(result: result)]
        }
    }
    
    private func loadMedia(result: PHPickerResult) async throws -> CleartextMedia {
        let isVideo = result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let preferredType = isVideo ? UTType.movie.identifier : UTType.image.identifier
        
        let url: URL? = try await withCheckedThrowingContinuation { continuation in
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: preferredType) { url, error in
                guard let url = url else {
                    debugPrint("Error loading file representation: \(String(describing: error))")
                    continuation.resume(returning: nil)
                    return
                }
                
                // Use helper to copy file
                let fileName = NSUUID().uuidString + (isVideo ? ".mov" : ".jpeg")
                let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)
                
                do {
                    try FileManager.default.copyItem(at: url, to: destinationURL)
                    debugPrint("File copied to: \(destinationURL)")
                    continuation.resume(returning: destinationURL)
                } catch {
                    debugPrint("Error copying file: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
        
        guard let url = url else {
            printDebug("Error loading file representation, url is nil")
            throw BackgroundImportError.mismatchedType
        }
        
        return CleartextMedia(source: url, mediaType: isVideo ? .video : .photo, id: UUID().uuidString)
    }
    
    private func loadLivePhoto(result: PHPickerResult) async throws -> [CleartextMedia] {
        let assetResources = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[PHAssetResource], Error>) in
            // Load the PHLivePhoto object from the picker result
            result.itemProvider.loadObject(ofClass: PHLivePhoto.self) { (object, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let livePhoto = object as? PHLivePhoto else {
                    continuation.resume(throwing: NSError(domain: "LivePhotoErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not load PHLivePhoto from the result"]))
                    return
                }
                
                continuation.resume(returning: PHAssetResource.assetResources(for: livePhoto))
            }
        }
        
        return try await processAssetResources(assetResources)
    }
    
    // MARK: - PHAsset Loading
    
    private func loadMediaFromAsset(_ asset: PHAsset) async throws -> [CleartextMedia] {
        // Handle live photos
        if asset.mediaSubtypes.contains(.photoLive) {
            return try await loadLivePhotoFromAsset(asset)
        } else {
            return [try await loadRegularMediaFromAsset(asset)]
        }
    }
    
    private func loadRegularMediaFromAsset(_ asset: PHAsset) async throws -> CleartextMedia {
        let isVideo = asset.mediaType == .video
        let id = UUID().uuidString
        
        if isVideo {
            // Handle video
            return try await withCheckedThrowingContinuation { continuation in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.version = .current
                
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    guard let urlAsset = avAsset as? AVURLAsset else {
                        // No asset back means PhotoKit refused, not that the type was
                        // wrong; `info` says which refusal it was.
                        continuation.resume(throwing: BackgroundImportError.fromPhotoKitInfo(info))
                        return
                    }
                    
                    let fileName = id + ".mov"
                    let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)
                    
                    do {
                        try FileManager.default.copyItem(at: urlAsset.url, to: destinationURL)
                        let media = CleartextMedia(source: destinationURL, mediaType: .video, id: id)
                        continuation.resume(returning: media)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } else {
            // Handle image
            return try await withCheckedThrowingContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.version = .current
                
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    guard let data = data else {
                        continuation.resume(throwing: BackgroundImportError.fromPhotoKitInfo(info))
                        return
                    }
                    
                    let fileName = id + ".jpeg"
                    let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)
                    
                    do {
                        try data.write(to: destinationURL)
                        let media = CleartextMedia(source: destinationURL, mediaType: .photo, id: id)
                        continuation.resume(returning: media)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func loadLivePhotoFromAsset(_ asset: PHAsset) async throws -> [CleartextMedia] {
        let resources = PHAssetResource.assetResources(for: asset)
        return try await processAssetResources(resources)
    }
    
    // MARK: - Helper Methods
    
    private func processAssetResources(_ resources: [PHAssetResource]) async throws -> [CleartextMedia] {
        var cleartextMediaArray: [CleartextMedia] = []
        let id = UUID().uuidString
        
        for resource in resources {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            
            let documentsDirectory = URL.tempMediaDirectory
            // Use a unique filename to avoid conflicts between imports
            let fileExtension = (resource.originalFilename as NSString).pathExtension
            let uniqueFileName = "\(UUID().uuidString).\(fileExtension.isEmpty ? "data" : fileExtension)"
            let fileURL = documentsDirectory.appendingPathComponent(uniqueFileName)
            
            var mediaType: MediaType
            switch resource.type {
            case .pairedVideo:
                mediaType = .video
            case .photo:
                mediaType = .photo
            default:
                printDebug("Error, could not handle media type \(resource.type)")
                continue
            }
            
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: fileURL, options: options)
            let media = CleartextMedia(
                source: fileURL,
                mediaType: mediaType,
                id: id
            )
            cleartextMediaArray.append(media)
        }
        
        return cleartextMediaArray
    }
    
    private func ensureTempDirectoryExists() async throws {
        if tempDirectoryChecked { return }
        
        let tempDir = URL.tempMediaDirectory
        var isDirectory: ObjCBool = false
        
        if !FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            printDebug("🗂️ Created temp directory: \(tempDir.path)")
        } else {
            printDebug("🗂️ Temp directory already exists: \(tempDir.path)")
        }
        
        tempDirectoryChecked = true
    }
    
    /// Logs media loading errors with detailed information
    private func logMediaLoadError(_ error: Error, for result: MediaSelectionResult) {
        let identifier: String
        switch result {
        case .phAsset(let asset): identifier = asset.localIdentifier
        case .phPickerResult(let picker): identifier = picker.assetIdentifier ?? "unknown"
        }
        
        printDebug("❌ Error loading media \(identifier): \(error)")
        if let nsError = error as NSError? {
            printDebug("❌ Error domain: \(nsError.domain), code: \(nsError.code)")
        }
    }
}
