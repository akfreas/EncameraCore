//
//  AppGroupFileAccess.swift
//  EncameraCore
//
//  Created by Alexander Freas on 11.05.23.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

/// Manages file access to the shared App Group container for sharing media between
/// the Share Extension and the main app.
public class AppGroupFileAccess: DebugPrintable {
    
    // MARK: - Shared Instance
    
    public static let shared = AppGroupFileAccess()
    
    // MARK: - Properties
    
    /// The root URL for the shared container's import directory
    public var importDirectoryURL: URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: UserDefaultUtils.appGroup) else {
            printDebug("ERROR: Could not get App Group container URL for identifier: \(UserDefaultUtils.appGroup)")
            return nil
        }
        return containerURL.appendingPathComponent("ImportImages")
    }
    
    // MARK: - Initialization
    
    public init() {
        initializeDirectoryIfNeeded()
    }
    
    // MARK: - Directory Management
    
    /// Ensures the import directory exists
    private func initializeDirectoryIfNeeded() {
        guard let url = importDirectoryURL else { return }
        
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                printDebug("Created import directory at: \(url.path)")
            } catch {
                printDebug("ERROR: Failed to create import directory: \(error)")
            }
        }
    }
    
    // MARK: - Saving Media
    
    /// Saves cleartext media to the App Group container
    /// - Parameters:
    ///   - media: The cleartext media to save
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: The URL where the file was saved
    @discardableResult
    public func save(media: CleartextMedia, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let containerURL = importDirectoryURL else {
            throw AppGroupFileAccessError.containerNotAvailable
        }
        
        initializeDirectoryIfNeeded()
        
        switch media.source {
        case .data(let data):
            let filename = "\(media.id).jpeg"
            let destinationURL = containerURL.appendingPathComponent(filename)
            
            printDebug("Saving media data to: \(destinationURL.path)")
            try data.write(to: destinationURL)
            progress(1.0)
            return destinationURL
            
        case .url(let sourceURL):
            let fileExtension = normalizeFileExtension(sourceURL.pathExtension)
            let filename = "\(media.id).\(fileExtension)"
            let destinationURL = containerURL.appendingPathComponent(filename)
            
            printDebug("Copying media from \(sourceURL.path) to \(destinationURL.path)")
            
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            progress(1.0)
            return destinationURL
        }
    }
    
    /// Normalizes file extensions for consistency
    private func normalizeFileExtension(_ ext: String) -> String {
        let lowercased = ext.lowercased()
        switch lowercased {
        case "jpg":
            return "jpeg"
        default:
            return lowercased
        }
    }
    
    // MARK: - Enumerating Media
    
    /// Returns all pending media files in the import directory
    public func enumerateMedia() async -> [CleartextMedia] {
        guard let containerURL = importDirectoryURL else {
            printDebug("ERROR: Container URL not available for enumeration")
            return []
        }
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            
            let filteredURLs = fileURLs.filter { url in
                MediaType.from(url: url) != .unknown
            }

            let media = filteredURLs.map { url -> CleartextMedia in
                var cleartextMedia = CleartextMedia(source: url)
                // Try to get creation date for timestamp
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let creationDate = attributes[.creationDate] as? Date {
                    cleartextMedia.timestamp = creationDate
                }
                return cleartextMedia
            }
            
            printDebug("Found \(media.count) pending media files in app group container")
            return media.sorted { ($0.timestamp ?? Date.distantPast) > ($1.timestamp ?? Date.distantPast) }
            
        } catch {
            printDebug("ERROR: Could not enumerate contents of directory: \(error)")
            return []
        }
    }
    
    /// Returns the count of pending media files without loading them all
    public func pendingMediaCount() -> Int {
        guard let containerURL = importDirectoryURL else { return 0 }
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            
            let count = fileURLs.filter { url in
                MediaType.from(url: url) != .unknown
            }.count
            
            return count
        } catch {
            return 0
        }
    }
    
    /// Checks if there are any pending media files
    public func hasPendingMedia() -> Bool {
        return pendingMediaCount() > 0
    }
    
    // MARK: - Deleting Media
    
    /// Deletes a specific media file from the import directory
    public func delete(media: CleartextMedia) async throws {
        guard case .url(let url) = media.source else {
            throw AppGroupFileAccessError.invalidMediaSource
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            printDebug("File already deleted or doesn't exist: \(url.path)")
            return
        }
        
        try FileManager.default.removeItem(at: url)
        printDebug("Deleted media file: \(url.lastPathComponent)")
    }
    
    /// Deletes multiple media files
    public func delete(mediaList: [CleartextMedia]) async throws {
        for media in mediaList {
            try await delete(media: media)
        }
    }
    
    /// Deletes all media files in the import directory
    public func deleteAllMedia() async throws {
        guard let containerURL = importDirectoryURL else {
            throw AppGroupFileAccessError.containerNotAvailable
        }
        
        let media = await enumerateMedia()
        
        for item in media {
            try await delete(media: item)
        }
        
        printDebug("Deleted all \(media.count) pending media files")
    }
    
    /// Clears the entire import directory (including any non-media files)
    public func clearImportDirectory() throws {
        guard let containerURL = importDirectoryURL else {
            throw AppGroupFileAccessError.containerNotAvailable
        }
        
        if FileManager.default.fileExists(atPath: containerURL.path) {
            try FileManager.default.removeItem(at: containerURL)
            printDebug("Cleared import directory")
        }
        
        // Recreate the empty directory
        initializeDirectoryIfNeeded()
    }
    
    // MARK: - Thumbnail Generation
    
    /// Generates a thumbnail for a cleartext media file
    public func loadThumbnail(for media: CleartextMedia, targetSize: CGSize = CGSize(width: 200, height: 200)) async throws -> UIImage? {
        guard case .url(let url) = media.source else {
            throw AppGroupFileAccessError.invalidMediaSource
        }
        
        let data = try await ThumbnailUtils.createThumbnailDataFrom(cleartext: media)
        return UIImage(data: data)
    }
}

// MARK: - Errors

public enum AppGroupFileAccessError: Error, LocalizedError {
    case containerNotAvailable
    case invalidMediaSource
    case fileNotFound
    case saveFailed(underlyingError: Error)
    
    public var errorDescription: String? {
        switch self {
        case .containerNotAvailable:
            return "App Group container is not available"
        case .invalidMediaSource:
            return "Invalid media source"
        case .fileNotFound:
            return "File not found"
        case .saveFailed(let error):
            return "Failed to save file: \(error.localizedDescription)"
        }
    }
}
