//
//  iCloudFilesManager.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.21.
//

import Foundation
import UIKit
import Combine
import AVFoundation



public actor DiskFileAccess: FileEnumerator {
    
    enum iCloudError: Error {
        case invalidURL
        case general
    }
    var key: PrivateKey?
    
    private var cancellables = Set<AnyCancellable>()
    private var directoryModel: DataStorageModel?
    
    public init() {}
    
    public init(with key: PrivateKey?, storageSettingsManager: DataStorageSetting) async {
        await configure(with: key, storageSettingsManager: storageSettingsManager)
    }
    
    public func configure(with key: PrivateKey?, storageSettingsManager: DataStorageSetting) async {
        self.key = key
        let storageModel = storageSettingsManager.storageModelFor(keyName: key?.name)
        self.directoryModel = storageModel
        try? self.directoryModel?.initializeDirectories()
    }
    
    
    public func enumerateMedia<T>() async -> [T] where T : MediaDescribing, T.MediaSource == URL {
        guard let directoryModel = directoryModel else {
            return []
        }
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .creationDateKey])
        
        var filter = [MediaType.photo.fileExtension]
        
        if FeatureToggle.isEnabled(feature: .enableVideo) {
            filter += [MediaType.video.fileExtension]
        }
        
        let urls: [URL] = directoryModel.enumeratorForStorageDirectory(
            resourceKeys: resourceKeys,
            fileExtensionFilter: filter
        )
        
        let imageItems: [T] = urls
            .sorted { (url1: URL, url2: URL) in
                guard let resourceValues1 = try? url1.resourceValues(forKeys: resourceKeys),
                      let creationDate1 = resourceValues1.creationDate,
                      let resourceValues2 = try? url2.resourceValues(forKeys: resourceKeys),
                      let creationDate2 = resourceValues2.creationDate else {
                    return false
                }
                return creationDate1.compare(creationDate2) == .orderedDescending
            }.compactMap { (itemUrl: URL) in
                return T(source: itemUrl)
            }
        return imageItems
    }
    
}


extension DiskFileAccess: FileReader {
    
    public func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL {
        
        guard let thumbnailPath = directoryModel?.previewURLForMedia(media) else {
            throw FileAccessError.missingDirectoryModel
        }
        let preview = T(source: thumbnailPath, mediaType: .preview, id: media.id)
        
        do {
            let existingPreview = try await loadMediaInMemory(media: preview) { _ in }
            return try PreviewModel(source: existingPreview)
        } catch {
            switch media.mediaType {
            case .photo:
                return try await createPreview(for: media)
            case .video:
                // We are signaling here that there is no thumbnail for the
                // video at this time. The preview strategy should be changed
                // so that an encrypted preview is stored in a certain region
                // of the file, so we can load the preview without decrypting
                // the entire file
                throw SecretFilesError.createVideoThumbnailError
            default:
                throw SecretFilesError.createThumbnailError
            }
        }
    }
    
    public func loadLeadingThumbnail() async throws -> UIImage? {
        let media: [EncryptedMedia] = await enumerateMedia()
        guard let firstMedia = media.first else {
            return nil
        }
        
        do {
            let cleartextPreview = try await loadMediaPreview(for: firstMedia)
            guard let thumbnail = UIImage(data: cleartextPreview.thumbnailMedia.source) else {
                return nil
            }
            return thumbnail
            
        } catch {
            debugPrint("Error loading media preview")
            return nil
        }
    }
    
    public func loadMediaInMemory<T: MediaDescribing>(media: T, progress: (Double) -> Void) async throws -> CleartextMedia<Data> {
        
        if var encrypted = media as? EncryptedMedia {
            if encrypted.needsDownload, let iCloudDirectoryModel = directoryModel as? iCloudStorageModel {
                encrypted = try await iCloudDirectoryModel.downloadFileFromiCloud(media: encrypted) { prog in
                    progress(prog)
                }
            }
            return try await decryptMedia(encrypted: encrypted, progress: progress)
        } else {
            fatalError()
        }
    }
    
    public func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL> {
        if var encrypted = media as? EncryptedMedia {
            if encrypted.needsDownload, let iCloudDirectoryModel = directoryModel as? iCloudStorageModel {
                encrypted = try await iCloudDirectoryModel.downloadFileFromiCloud(media: encrypted) { prog in
                    progress(prog)
                }
            }
            return try await decryptMedia(encrypted: encrypted, progress: progress)
        } else if let cleartext = media as? CleartextMedia<URL> {
            return cleartext
        }
        
        fatalError()
    }
    private func decryptMedia(encrypted: EncryptedMedia, progress: (Double) -> Void) async throws -> CleartextMedia<Data> {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }
        let sourceURL = encrypted.source
        
        _ = sourceURL.startAccessingSecurityScopedResource()
        
        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: encrypted)
        
        let decrypted: CleartextMedia<Data> = try await fileHandler.decrypt()
        sourceURL.stopAccessingSecurityScopedResource()
        return decrypted
    }
    
    private func decryptMedia(encrypted: EncryptedMedia, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL> {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }
        let sourceURL = encrypted.source
        
        _ = sourceURL.startAccessingSecurityScopedResource()
        let targetURL = URL.tempMediaDirectory
            .appendingPathComponent(encrypted.id)
            .appendingPathExtension("mov")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            return CleartextMedia(source: targetURL)
        }
        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: encrypted, targetURL: targetURL
        )
        fileHandler.progress
            .receive(on: DispatchQueue.main)
            .sink { percent in
                progress(percent)
            }.store(in: &cancellables)
        let decrypted: CleartextMedia<URL> = try await fileHandler.decrypt()
        sourceURL.stopAccessingSecurityScopedResource()
        return decrypted
    }
    private func generateThumbnailFromVideo(at path: URL) -> UIImage? {
        do {
            let asset = AVURLAsset(url: path, options: nil)
            let imgGenerator = AVAssetImageGenerator(asset: asset)
            imgGenerator.appliesPreferredTrackTransform = true
            let cgImage = try imgGenerator.copyCGImage(at: CMTimeMake(value: 0, timescale: 1), actualTime: nil)
            
            let thumbnail = UIImage(cgImage: cgImage)
            return thumbnail
        } catch let error {
            debugPrint("Error generating thumbnail at path \(path): \(error.localizedDescription)")
            return nil
        }
    }
    
    @discardableResult public func createPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel {
        
        let thumbnail = try await createThumbnail(for: media)
        var preview = PreviewModel(thumbnailMedia: thumbnail)
        if let encrypted = media as? EncryptedMedia {
            switch encrypted.mediaType {
            case .photo:
                break
            case .video:
                let video: CleartextMedia<URL> = try await decryptMedia(encrypted: encrypted, progress: {_ in })
                let asset = AVURLAsset(url: video.source, options: nil)
                preview.videoDuration = asset.duration.durationText
            default:
                throw SecretFilesError.createPreviewError
            }
        } else if let decrypted = media as? CleartextMedia<URL>, decrypted.mediaType == .video {
            let asset = AVURLAsset(url: decrypted.source, options: nil)
            preview.videoDuration = asset.duration.durationText
        }
        try await savePreview(preview: preview, sourceMedia: media)
        
        return preview
    }
    
    @discardableResult private func createThumbnail<T: MediaDescribing>(for media: T) async throws -> CleartextMedia<Data> {
        
        
        var thumbnailSourceData: Data
        if let encrypted = media as? EncryptedMedia {
            
            switch encrypted.mediaType {
                
            case .photo:
                let decrypted: CleartextMedia<Data> = try await self.decryptMedia(encrypted: encrypted) { _ in }
                thumbnailSourceData = decrypted.source
                
            case .video:
                let decrypted: CleartextMedia<URL> = try await self.decryptMedia(encrypted: encrypted) { _ in }
                guard let thumb = self.generateThumbnailFromVideo(at: decrypted.source),
                      let data = thumb.pngData() else {
                    throw SecretFilesError.createVideoThumbnailError
                }
                thumbnailSourceData = data
            default:
                throw SecretFilesError.fileTypeError
            }
        } else if let cleartext = media as? CleartextMedia<URL> {
            switch cleartext.mediaType {
            case .photo:
                thumbnailSourceData = try Data(contentsOf: cleartext.source)
            case .video:
                guard let thumb = self.generateThumbnailFromVideo(at: cleartext.source),
                      let data = thumb.pngData() else {
                    throw SecretFilesError.createVideoThumbnailError
                }
                thumbnailSourceData = data
            default:
                throw SecretFilesError.fileTypeError
            }
        } else if let cleartext = media as? CleartextMedia<Data> {
            switch cleartext.mediaType {
            case .photo:
                thumbnailSourceData = cleartext.source
            default:
                throw SecretFilesError.fileTypeError
            }
        } else {
            fatalError()
        }
        let resizer = ImageResizer(targetWidth: AppConstants.thumbnailWidth)
        guard let thumbnailData = resizer.resize(data: thumbnailSourceData)?.pngData() else {
            fatalError()
        }
        
        
        let cleartextThumb = CleartextMedia(source: thumbnailData, mediaType: .photo, id: media.id)
        return cleartextThumb
        
    }
}



extension DiskFileAccess: FileWriter {
        
    @discardableResult public func savePreview<T: MediaDescribing>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia<Data> {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }
        let data = try JSONEncoder().encode(preview)
        let destinationURL = directoryModel?.previewURLForMedia(sourceMedia)
        let cleartextPreview = CleartextMedia(source: data, mediaType: .preview, id: sourceMedia.id)
        
        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartextPreview, targetURL: destinationURL)
        try await fileHandler.encrypt()
        return cleartextPreview
    }
    
    @discardableResult public func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }
        let destinationURL = directoryModel?.driveURLForNewMedia(media)
        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: media, targetURL: destinationURL)
        let encrypted = try await fileHandler.encrypt()
        try await createPreview(for: media)
        operationBus.didCreate(encrypted)
        return encrypted
    }
    
    public func copy(media: EncryptedMedia) async throws {
        guard let destinationURL = directoryModel?.driveURLForNewMedia(media) else {
            throw FileAccessError.missingDirectoryModel
        }
        try FileManager.default.moveItem(at: media.source, to: destinationURL)
        if let newMedia = EncryptedMedia(source: destinationURL) {
            operationBus.didCreate(newMedia)
        }
    }
    
    public func delete(media: EncryptedMedia) async throws {
        
        try FileManager.default.removeItem(at: media.source)
        if let previewURL = directoryModel?.previewURLForMedia(media) {
            try FileManager.default.removeItem(at: previewURL)
        }
        operationBus.didDelete(media)
        
    }
    
    public func deleteMediaForKey() async throws {
        
        guard let url = directoryModel?.baseURL else {
            throw FileAccessError.missingPrivateKey
        }
        
        try FileManager.default.removeItem(at: url)
    }
    public func deleteAllMedia() async throws {
        let storset = DataStorageUserDefaultsSetting()
        for type in StorageType.allCases {
            guard case .available = storset.isStorageTypeAvailable(type: type) else {
                continue
            }
            do {
                try type.modelForType.init(keyName: "").deleteAllFiles()
            } catch {
                print("Could not delete all files for \(type): ", error)
            }
        }
    }
    
    public func moveAllMedia(for keyName: KeyName, toRenamedKey newKeyName: KeyName) async throws {
        
    }
    
}

extension DiskFileAccess: FileAccess {
    
}

extension UIImage {
    func scalePreservingAspectRatio(targetSize: CGSize) -> UIImage {
        // Determine the scale factor that preserves aspect ratio
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        
        let scaleFactor = min(widthRatio, heightRatio)
        
        // Compute the new image size that preserves aspect ratio
        let scaledImageSize = CGSize(
            width: size.width * scaleFactor,
            height: size.height * scaleFactor
        )
        
        // Draw and return the resized UIImage
        let renderer = UIGraphicsImageRenderer(
            size: scaledImageSize
        )
        
        let scaledImage = renderer.image { _ in
            self.draw(in: CGRect(
                origin: .zero,
                size: scaledImageSize
            ))
        }
        
        return scaledImage
    }
}
