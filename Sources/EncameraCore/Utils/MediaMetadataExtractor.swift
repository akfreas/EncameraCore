//
//  MediaMetadataExtractor.swift
//  EncameraCore
//
//  Created for encrypted file metadata storage feature.
//

import Foundation
import Photos
import AVFoundation
import ImageIO
import CoreLocation

#if canImport(UIKit)
import UIKit
#endif

/// Extracts metadata from various media sources for embedding in encrypted files
public struct MediaMetadataExtractor {
    
    public init() {}
    
    // MARK: - PHAsset Extraction
    
    /// Extracts metadata from a PHAsset
    /// - Parameter asset: The Photos framework asset
    /// - Returns: Populated EncryptedFileMetadata
    /// The Photos-recorded filename (e.g. `IMG_1234.HEIC`) of the asset's
    /// primary resource — the still photo or video, not adjustments or the
    /// Live Photo's paired video.
    public static func primaryResourceFilename(for asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        let primaryTypes: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto]
        let primary = resources.first { primaryTypes.contains($0.type) } ?? resources.first
        return primary?.originalFilename
    }

    public func extractMetadata(from asset: PHAsset) async -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()

        // Store the PHAsset identifier for import tracking
        metadata.sourceAssetIdentifier = asset.localIdentifier
        metadata.originalFilename = Self.primaryResourceFilename(for: asset)
        
        // Core dates
        metadata.captureDate = asset.creationDate
        metadata.modificationDate = asset.modificationDate
        metadata.encryptionDate = Date()
        
        // Location
        if let location = asset.location {
            metadata.location = extractLocation(from: location)
        }
        
        // Dimensions
        metadata.dimensions = .init(
            width: asset.pixelWidth,
            height: asset.pixelHeight
        )
        
        // Media type
        switch asset.mediaType {
        case .image:
            metadata.originalMediaType = "photo"
        case .video:
            metadata.originalMediaType = "video"
            metadata.video = .init(duration: asset.duration)
        case .audio:
            metadata.originalMediaType = "audio"
        case .unknown:
            metadata.originalMediaType = "unknown"
        @unknown default:
            metadata.originalMediaType = "unknown"
        }
        
        // Content analysis from asset subtypes
        var analysis = EncryptedFileMetadata.ContentAnalysis()
        analysis.isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
        analysis.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        analysis.isBurst = asset.representsBurst
        analysis.burstIdentifier = asset.burstIdentifier
        metadata.contentAnalysis = analysis
        
        // Extract EXIF data from image data (async)
        if asset.mediaType == .image {
            metadata.camera = await extractCameraInfo(from: asset)
        } else if asset.mediaType == .video {
            let videoInfo = await extractVideoInfo(from: asset)
            if let info = videoInfo {
                metadata.video = info
            }
        }
        
        return metadata
    }
    
    // MARK: - Image Data Extraction
    
    /// Extracts metadata from raw image data
    /// - Parameter imageData: Raw image bytes
    /// - Returns: Populated EncryptedFileMetadata
    public func extractMetadata(from imageData: Data) -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.encryptionDate = Date()
        metadata.originalMediaType = "photo"
        metadata.originalFileSize = UInt64(imageData.count)
        
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return metadata
        }
        
        // Extract image properties
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
            metadata.camera = extractCameraInfo(from: properties)
            metadata.dimensions = extractDimensions(from: properties)
            
            // Extract capture date from EXIF
            if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                metadata.captureDate = parseExifDate(dateString)
            }
            
            // Extract GPS info
            if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
                metadata.location = extractLocation(from: gps)
            }
        }
        
        return metadata
    }
    
    /// Extracts metadata from a UIImage (limited info available)
    #if canImport(UIKit)
    public func extractMetadata(from image: UIImage) -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.encryptionDate = Date()
        metadata.originalMediaType = "photo"
        
        metadata.dimensions = .init(
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale)
        )
        
        // EXIF orientation from UIImage orientation
        let orientation: Int
        switch image.imageOrientation {
        case .up: orientation = 1
        case .down: orientation = 3
        case .left: orientation = 8
        case .right: orientation = 6
        case .upMirrored: orientation = 2
        case .downMirrored: orientation = 4
        case .leftMirrored: orientation = 5
        case .rightMirrored: orientation = 7
        @unknown default: orientation = 1
        }
        
        metadata.camera = .init(orientation: orientation)
        
        return metadata
    }
    #endif
    
    // MARK: - URL Extraction
    
    /// Extracts metadata from a file URL
    /// - Parameters:
    ///   - url: URL to the media file
    ///   - mediaType: Type of media (photo or video)
    /// - Returns: Populated EncryptedFileMetadata
    public func extractMetadata(from url: URL, mediaType: MediaType) async -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.encryptionDate = Date()
        metadata.originalExtension = url.pathExtension.lowercased()
        // Temp copies are named exactly UUID().uuidString + extension; recording
        // those would persist garbage, so only keep names with non-UUID stems
        // (same rule the UI applies via displayFilename).
        metadata.originalFilename = url.lastPathComponent
        metadata.originalFilename = metadata.displayFilename
        
        // Get file attributes
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            metadata.captureDate = attrs[.creationDate] as? Date
            metadata.modificationDate = attrs[.modificationDate] as? Date
            metadata.originalFileSize = attrs[.size] as? UInt64
        }
        
        switch mediaType {
        case .photo:
            metadata.originalMediaType = "photo"
            if let data = try? Data(contentsOf: url) {
                let imageMetadata = extractMetadata(from: data)
                // Merge image-specific metadata
                metadata.camera = imageMetadata.camera
                metadata.dimensions = imageMetadata.dimensions
                metadata.location = imageMetadata.location ?? metadata.location
                if let exifDate = imageMetadata.captureDate {
                    metadata.captureDate = exifDate
                }
            }
            
        case .video:
            metadata.originalMediaType = "video"
            let videoInfo = await extractVideoInfo(from: url)
            metadata.video = videoInfo
            metadata.dimensions = await extractVideoDimensions(from: url)
            
        default:
            break
        }
        
        return metadata
    }
    
    // MARK: - Private Helpers
    
    private func extractLocation(from clLocation: CLLocation) -> EncryptedFileMetadata.Location {
        return .init(
            latitude: clLocation.coordinate.latitude,
            longitude: clLocation.coordinate.longitude,
            altitude: clLocation.altitude,
            horizontalAccuracy: clLocation.horizontalAccuracy,
            verticalAccuracy: clLocation.verticalAccuracy,
            timestamp: clLocation.timestamp
        )
    }
    
    private func extractLocation(from gps: [String: Any]) -> EncryptedFileMetadata.Location? {
        guard let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double else {
            return nil
        }
        
        var lat = latitude
        var lon = longitude
        
        // Apply reference direction
        if let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String, latRef == "S" {
            lat = -lat
        }
        if let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String, lonRef == "W" {
            lon = -lon
        }
        
        return .init(
            latitude: lat,
            longitude: lon,
            altitude: gps[kCGImagePropertyGPSAltitude as String] as? Double
        )
    }
    
    private func extractCameraInfo(from properties: [String: Any]) -> EncryptedFileMetadata.CameraInfo? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        
        guard exif != nil || tiff != nil else { return nil }
        
        var camera = EncryptedFileMetadata.CameraInfo()
        
        // TIFF properties
        if let tiff = tiff {
            camera.deviceMake = tiff[kCGImagePropertyTIFFMake as String] as? String
            camera.deviceModel = tiff[kCGImagePropertyTIFFModel as String] as? String
            camera.software = tiff[kCGImagePropertyTIFFSoftware as String] as? String
            camera.orientation = tiff[kCGImagePropertyTIFFOrientation as String] as? Int
        }
        
        // EXIF properties
        if let exif = exif {
            camera.aperture = exif[kCGImagePropertyExifFNumber as String] as? Double
            camera.exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
            camera.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
            camera.focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double
            camera.focalLength35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int
            camera.lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
            
            // Flash
            if let flash = exif[kCGImagePropertyExifFlash as String] as? Int {
                camera.flashFired = (flash & 1) == 1
            }
            
            // Format shutter speed
            if let exposure = camera.exposureTime {
                if exposure >= 1 {
                    camera.shutterSpeed = String(format: "%.1f\"", exposure)
                } else if exposure > 0 {
                    camera.shutterSpeed = String(format: "1/%.0f", 1.0 / exposure)
                }
            }
        }
        
        return camera
    }
    
    private func extractCameraInfo(from asset: PHAsset) async -> EncryptedFileMetadata.CameraInfo? {
        return await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let input = input,
                      let fullImageURL = input.fullSizeImageURL,
                      let imageSource = CGImageSourceCreateWithURL(fullImageURL as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let camera = self.extractCameraInfo(from: properties)
                continuation.resume(returning: camera)
            }
        }
    }
    
    private func extractDimensions(from properties: [String: Any]) -> EncryptedFileMetadata.Dimensions? {
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        
        return .init(
            width: width,
            height: height,
            pixelDensity: properties[kCGImagePropertyDPIWidth as String] as? Int
        )
    }
    
    private func extractVideoInfo(from asset: PHAsset) async -> EncryptedFileMetadata.VideoInfo? {
        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: EncryptedFileMetadata.VideoInfo(duration: asset.duration))
                    return
                }
                
                Task {
                    let info = await self.extractVideoInfo(from: urlAsset)
                    continuation.resume(returning: info)
                }
            }
        }
    }
    
    private func extractVideoInfo(from url: URL) async -> EncryptedFileMetadata.VideoInfo? {
        let asset = AVURLAsset(url: url)
        return await extractVideoInfo(from: asset)
    }
    
    private func extractVideoInfo(from asset: AVURLAsset) async -> EncryptedFileMetadata.VideoInfo {
        // Load asset duration asynchronously
        let duration = (try? await asset.load(.duration)) ?? CMTime.zero
        var info = EncryptedFileMetadata.VideoInfo(duration: CMTimeGetSeconds(duration))
        
        // Load video tracks asynchronously
        let videoTracks = try? await asset.loadTracks(withMediaType: .video)
        if let videoTrack = videoTracks?.first {
            // Load video track properties asynchronously
            async let frameRate = try? videoTrack.load(.nominalFrameRate)
            async let bitRate = try? videoTrack.load(.estimatedDataRate)
            async let formatDescriptions = try? videoTrack.load(.formatDescriptions)
            
            let (loadedFrameRate, loadedBitRate, loadedFormatDescriptions) = await (frameRate, bitRate, formatDescriptions)
            
            if let frameRate = loadedFrameRate {
                info.frameRate = Double(frameRate)
            }
            if let bitRate = loadedBitRate {
                info.bitRate = Int(bitRate)
            }
            
            // Codec
            if let formatDescriptions = loadedFormatDescriptions,
               let formatDescription = formatDescriptions.first {
                let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
                info.codec = fourCharCodeToString(codecType)
            }
        }
        
        // Load audio tracks asynchronously
        let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks?.first {
            info.hasAudio = true
            
            // Codec
            if let formatDescriptions = try? await audioTrack.load(.formatDescriptions),
               let formatDescription = formatDescriptions.first {
                let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
                info.audioCodec = fourCharCodeToString(codecType)
            }
        } else {
            info.hasAudio = false
        }
        
        return info
    }
    
    private func extractVideoDimensions(from url: URL) async -> EncryptedFileMetadata.Dimensions? {
        let asset = AVURLAsset(url: url)
        
        // Load video tracks asynchronously
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              let videoTrack = videoTracks.first else {
            return nil
        }
        
        // Load track properties asynchronously
        async let naturalSize = try? videoTrack.load(.naturalSize)
        async let preferredTransform = try? videoTrack.load(.preferredTransform)
        
        guard let size = await naturalSize,
              let transform = await preferredTransform else {
            return nil
        }
        
        // Apply transform to get actual dimensions
        let transformedSize = size.applying(transform)
        
        return .init(
            width: Int(abs(transformedSize.width)),
            height: Int(abs(transformedSize.height))
        )
    }
    
    private func parseExifDate(_ string: String) -> Date? {
        // EXIF date format: "2024:01:15 14:30:00"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: string)
    }
    
    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }
}
