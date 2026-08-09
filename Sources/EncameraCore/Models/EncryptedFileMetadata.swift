//
//  EncryptedFileMetadata.swift
//  EncameraCore
//
//  Created for encrypted file metadata storage feature.
//

import Foundation

/// File format constants for encrypted files
public enum EncryptedFileFormat {
    /// Magic bytes for v2 format: "ENC2"
    public static let magic: [UInt8] = [0x45, 0x4E, 0x43, 0x32]
    public static let magicSize = 4
    
    /// Current format version
    public static let version: UInt16 = 2
    public static let versionSize = 2
    
    /// Flags field size (reserved for future use)
    public static let flagsSize = 2
    
    /// Metadata length field size
    public static let metadataLengthSize = 4
    
    /// XChaCha20-Poly1305 stream header size
    public static let streamHeaderSize = 24
    
    /// Total fixed header size before variable-length metadata content
    /// = magic(4) + version(2) + flags(2) + length(4) + streamHeader(24) = 36 bytes
    public static let fixedHeaderSize = magicSize + versionSize + flagsSize + metadataLengthSize + streamHeaderSize
    
    /// Offset where the metadata length field starts
    public static let metadataLengthOffset = magicSize + versionSize + flagsSize
    
    /// Maximum allowed metadata size (1 MB)
    public static let maxMetadataSize: UInt32 = 1024 * 1024
}

/// Encrypted file metadata - stored at the beginning of v2 encrypted files
/// Enables fast sorting and filtering without decrypting the entire file content
public struct EncryptedFileMetadata: Codable, Equatable, Sendable {
    
    /// Schema version for metadata format evolution
    public var schemaVersion: Int = 1
    
    // MARK: - Core Timestamps
    
    /// Original capture/creation date from the source media
    public var captureDate: Date?
    
    /// Date when the file was encrypted
    public var encryptionDate: Date?
    
    /// Last modification date of the original file
    public var modificationDate: Date?
    
    // MARK: - Location
    
    public var location: Location?
    
    // MARK: - Camera/Device Info
    
    public var camera: CameraInfo?
    
    // MARK: - Image Properties
    
    public var dimensions: Dimensions?
    
    // MARK: - Video Properties
    
    public var video: VideoInfo?
    
    // MARK: - Media Classification
    
    /// Original media type before encryption: "photo", "video", "livePhoto"
    public var originalMediaType: String?
    
    /// Original file extension (e.g., "jpg", "heic", "mov")
    public var originalExtension: String?
    
    /// Original filename (optional, may be privacy-sensitive)
    public var originalFilename: String?
    
    /// MIME type of original content
    public var mimeType: String?
    
    /// File size in bytes (unencrypted)
    public var originalFileSize: UInt64?
    
    // MARK: - Import Tracking
    
    /// PHAsset local identifier for imported media
    /// Used to track which photos have been imported and avoid duplicates
    public var sourceAssetIdentifier: String?
    
    // MARK: - Content Analysis
    
    public var contentAnalysis: ContentAnalysis?
    
    // MARK: - Custom/User Tags
    
    /// User-defined tags for organization
    public var tags: [String]?
    
    /// Custom key-value metadata (extensibility)
    public var customFields: [String: String]?
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Computed Properties
    
    /// Primary date for sorting (captureDate or encryptionDate fallback)
    public var primaryDate: Date? {
        return captureDate ?? encryptionDate
    }

    /// `originalFilename` suitable for display: historical imports recorded
    /// UUID-named temp copies (`UUID().uuidString + "." + ext`), which are
    /// meaningless to the user, so those are suppressed.
    public var displayFilename: String? {
        guard let originalFilename else { return nil }
        let stem = (originalFilename as NSString).deletingPathExtension
        guard UUID(uuidString: stem) == nil else { return nil }
        return originalFilename
    }
    
    /// Aspect ratio if dimensions are available
    public var aspectRatio: Double? {
        guard let dim = dimensions, dim.height > 0 else { return nil }
        return Double(dim.width) / Double(dim.height)
    }
    
    /// Duration formatted as string (for videos)
    public var formattedDuration: String? {
        guard let duration = video?.duration else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Check if this is a portrait orientation image
    public var isPortrait: Bool {
        guard let ratio = aspectRatio else { return false }
        return ratio < 1.0
    }
    
    /// Check if this is a landscape orientation image
    public var isLandscape: Bool {
        guard let ratio = aspectRatio else { return false }
        return ratio > 1.0
    }
}

// MARK: - Nested Types

extension EncryptedFileMetadata {
    
    /// Geographic location data
    public struct Location: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?
        public var horizontalAccuracy: Double?
        public var verticalAccuracy: Double?
        public var timestamp: Date?
        
        // Reverse geocoded data (optional, for display)
        public var placeName: String?
        /// City
        public var locality: String?
        /// State/Province
        public var administrativeArea: String?
        public var country: String?
        public var isoCountryCode: String?
        
        public init(
            latitude: Double,
            longitude: Double,
            altitude: Double? = nil,
            horizontalAccuracy: Double? = nil,
            verticalAccuracy: Double? = nil,
            timestamp: Date? = nil,
            placeName: String? = nil,
            locality: String? = nil,
            administrativeArea: String? = nil,
            country: String? = nil,
            isoCountryCode: String? = nil
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.horizontalAccuracy = horizontalAccuracy
            self.verticalAccuracy = verticalAccuracy
            self.timestamp = timestamp
            self.placeName = placeName
            self.locality = locality
            self.administrativeArea = administrativeArea
            self.country = country
            self.isoCountryCode = isoCountryCode
        }
        
        /// Formatted location string for display
        public var displayString: String {
            var parts: [String] = []
            if let place = placeName { parts.append(place) }
            if let city = locality { parts.append(city) }
            if let area = administrativeArea { parts.append(area) }
            if let country = country { parts.append(country) }
            
            if parts.isEmpty {
                return String(format: "%.4f, %.4f", latitude, longitude)
            }
            return parts.joined(separator: ", ")
        }
    }
    
    /// Camera and device information (EXIF-like)
    public struct CameraInfo: Codable, Equatable, Sendable {
        // Device
        /// Device manufacturer (e.g., "Apple")
        public var deviceMake: String?
        /// Device model (e.g., "iPhone 15 Pro")
        public var deviceModel: String?
        
        // Camera settings
        /// Aperture f-number (e.g., 1.8)
        public var aperture: Double?
        /// Shutter speed string (e.g., "1/120")
        public var shutterSpeed: String?
        /// Exposure time in seconds
        public var exposureTime: Double?
        /// ISO sensitivity
        public var iso: Int?
        /// Focal length in mm
        public var focalLength: Double?
        /// 35mm equivalent focal length
        public var focalLength35mm: Int?
        /// Lens model identifier
        public var lensModel: String?
        
        // Flash
        /// Whether flash was fired
        public var flashFired: Bool?
        /// Flash mode description
        public var flashMode: String?
        
        // Orientation
        /// EXIF orientation value (1-8)
        public var orientation: Int?
        
        // Software
        /// Software/app that created the image
        public var software: String?
        
        public init(
            deviceMake: String? = nil,
            deviceModel: String? = nil,
            aperture: Double? = nil,
            shutterSpeed: String? = nil,
            exposureTime: Double? = nil,
            iso: Int? = nil,
            focalLength: Double? = nil,
            focalLength35mm: Int? = nil,
            lensModel: String? = nil,
            flashFired: Bool? = nil,
            flashMode: String? = nil,
            orientation: Int? = nil,
            software: String? = nil
        ) {
            self.deviceMake = deviceMake
            self.deviceModel = deviceModel
            self.aperture = aperture
            self.shutterSpeed = shutterSpeed
            self.exposureTime = exposureTime
            self.iso = iso
            self.focalLength = focalLength
            self.focalLength35mm = focalLength35mm
            self.lensModel = lensModel
            self.flashFired = flashFired
            self.flashMode = flashMode
            self.orientation = orientation
            self.software = software
        }
        
        /// Formatted camera settings for display (e.g., "f/1.8  1/120  ISO 100")
        public var settingsString: String? {
            var parts: [String] = []
            if let f = aperture { parts.append("f/\(String(format: "%.1f", f))") }
            if let ss = shutterSpeed { parts.append(ss) }
            if let iso = iso { parts.append("ISO \(iso)") }
            return parts.isEmpty ? nil : parts.joined(separator: "  ")
        }
    }
    
    /// Image/video dimensions
    public struct Dimensions: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// Pixel density (DPI)
        public var pixelDensity: Int?
        
        public init(width: Int, height: Int, pixelDensity: Int? = nil) {
            self.width = width
            self.height = height
            self.pixelDensity = pixelDensity
        }
        
        /// Megapixels
        public var megapixels: Double {
            return Double(width * height) / 1_000_000
        }
        
        /// Formatted dimensions string (e.g., "4032 × 3024")
        public var displayString: String {
            return "\(width) × \(height)"
        }
    }
    
    /// Video-specific properties
    public struct VideoInfo: Codable, Equatable, Sendable {
        /// Duration in seconds
        public var duration: TimeInterval
        /// Frames per second
        public var frameRate: Double?
        /// Bitrate in bits per second
        public var bitRate: Int?
        /// Video codec
        public var codec: String?
        /// Whether the video has an audio track
        public var hasAudio: Bool?
        /// Audio codec
        public var audioCodec: String?
        
        public init(
            duration: TimeInterval,
            frameRate: Double? = nil,
            bitRate: Int? = nil,
            codec: String? = nil,
            hasAudio: Bool? = nil,
            audioCodec: String? = nil
        ) {
            self.duration = duration
            self.frameRate = frameRate
            self.bitRate = bitRate
            self.codec = codec
            self.hasAudio = hasAudio
            self.audioCodec = audioCodec
        }
    }
    
    /// Content analysis data (computed on-device)
    public struct ContentAnalysis: Codable, Equatable, Sendable {
        /// Dominant colors (hex strings)
        public var dominantColors: [String]?
        
        /// Average brightness (0.0 - 1.0)
        public var brightness: Double?
        
        /// Is this likely a screenshot?
        public var isScreenshot: Bool?
        
        /// Is this a Live Photo?
        public var isLivePhoto: Bool?
        
        /// Is this a burst photo?
        public var isBurst: Bool?
        
        /// Burst identifier (for grouping burst photos)
        public var burstIdentifier: String?
        
        /// Number of detected faces
        public var facesDetected: Int?
        
        public init(
            dominantColors: [String]? = nil,
            brightness: Double? = nil,
            isScreenshot: Bool? = nil,
            isLivePhoto: Bool? = nil,
            isBurst: Bool? = nil,
            burstIdentifier: String? = nil,
            facesDetected: Int? = nil
        ) {
            self.dominantColors = dominantColors
            self.brightness = brightness
            self.isScreenshot = isScreenshot
            self.isLivePhoto = isLivePhoto
            self.isBurst = isBurst
            self.burstIdentifier = burstIdentifier
            self.facesDetected = facesDetected
        }
    }
}

// MARK: - Errors

public enum EncryptedMetadataError: Error, LocalizedError {
    case invalidFormat
    case unsupportedVersion(UInt16)
    case invalidMetadataSize(UInt32)
    case readError
    case decryptionFailed
    case encryptionFailed
    case fileNotFound
    case v1FileNoMetadata
    
    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid encrypted file format"
        case .unsupportedVersion(let version):
            return "Unsupported file format version: \(version)"
        case .invalidMetadataSize(let size):
            return "Invalid metadata size: \(size) bytes"
        case .readError:
            return "Failed to read file data"
        case .decryptionFailed:
            return "Failed to decrypt metadata"
        case .encryptionFailed:
            return "Failed to encrypt metadata"
        case .fileNotFound:
            return "Encrypted file not found"
        case .v1FileNoMetadata:
            return "V1 format file does not contain embedded metadata"
        }
    }
}

// MARK: - Device Info Utilities

/// Utilities for getting device information for metadata
/// Note: There is no system API to get human-readable device names from machine identifiers.
/// The mapping is auto-generated from: https://gist.github.com/adamawolf/3048717
/// To update the mapping, run: python3 Scripts/generate_device_mapping.py
public enum DeviceInfo {
    
    /// Returns the machine identifier (e.g., "iPhone16,1")
    public static var machineIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }
    
    /// Returns the human-readable device model name (e.g., "iPhone 15 Pro")
    /// Falls back to the machine identifier if no mapping exists
    public static var modelName: String {
        return DeviceModelMapping.modelName(for: machineIdentifier) ?? machineIdentifier
    }
    
    /// Returns "Apple" for all iOS devices
    public static var make: String {
        return "Apple"
    }
    
    /// Returns the app's software version string for metadata
    public static var softwareVersion: String {
        let bundleId = Bundle.main.bundleIdentifier ?? "Encamera"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "\(bundleId) \(version)".trimmingCharacters(in: .whitespaces)
    }
    
    /// Creates a CameraInfo populated with current device information
    /// - Parameters:
    ///   - flashFired: Whether flash was fired
    ///   - flashMode: Flash mode description
    /// - Returns: CameraInfo with device details populated
    public static func currentDeviceCameraInfo(
        flashFired: Bool? = nil,
        flashMode: String? = nil
    ) -> EncryptedFileMetadata.CameraInfo {
        return EncryptedFileMetadata.CameraInfo(
            deviceMake: make,
            deviceModel: modelName,
            flashFired: flashFired,
            flashMode: flashMode,
            software: softwareVersion
        )
    }
}
