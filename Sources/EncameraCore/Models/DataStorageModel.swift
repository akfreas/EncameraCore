//
//  DataStorageModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation
import Combine

public protocol DataStorageModel {
    var baseURL: URL { get }
    var album: Album { get }
    static var thumbnailDirectory: URL { get }
    var storageType: StorageType { get }
    
    init(album: Album)
    func initializeDirectories() throws
    static var rootURL: URL { get }
    static func enumerateRootDirectory() -> [URL]
}

enum DataStorageModelError: Error {
    case noURLForiCloudDownload
    case couldNotCreateMedia
}

extension DataStorageModel {

    static func enumeratorForStorageDirectory(at url: URL, resourceKeys: Set<URLResourceKey> = [], fileExtensionFilter: [String]? = nil, exclude: [String] = [], onlyDirectories: Bool = false) -> [URL] {
        let driveUrl = url
        _ = driveUrl.startAccessingSecurityScopedResource()

        var directoryContents: [URL]
        do {
            directoryContents = try FileManager.default.contentsOfDirectory(at: driveUrl, includingPropertiesForKeys: Array(resourceKeys), options: [])
        } catch {
            driveUrl.stopAccessingSecurityScopedResource()
            print("Error while enumerating files \(driveUrl.path): \(error.localizedDescription)")
            return []
        }

        driveUrl.stopAccessingSecurityScopedResource()

        let filteredContents = directoryContents.filter { url in
            // Exclude .Trash directory
            if url.lastPathComponent == ".Trash" {
                return false
            }

            // Apply user-defined exclusions
            for excludeString in exclude {
                if url.path.contains(excludeString) {
                    return false
                }
            }

            // Filter for directories only if required
            if onlyDirectories {
                let isDirectory: Bool
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                    isDirectory = resourceValues.isDirectory ?? false
                } catch {
                    print("Error reading resource values for \(url.path): \(error)")
                    return false
                }
                return isDirectory
            }

            return true
        }

        if let fileExtensionFilter = fileExtensionFilter {
            return filteredContents.filter({
                let components = $0.lastPathComponent.split(separator: ".")
                guard components.count > 1 else {
                    return false
                }

                // Account for .icloud final extension, just take the "middle" extension
                guard let fileExtension = components[safe: 1] else { return false }
                return fileExtensionFilter.contains(where: { $0.lowercased() == fileExtension })
            })
        }
        return filteredContents
    }


    public static func enumerateRootDirectory() -> [URL] {
        return enumeratorForStorageDirectory(
            at: rootURL,
            exclude: [AppConstants.previewDirectory, "thumbs"],
            onlyDirectories: true)
    }

    public static var thumbnailDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let thumbnailDirectory = documentsDirectory.appendingPathComponent(AppConstants.previewDirectory, isDirectory: true)
        return thumbnailDirectory
    }
    
    public func initializeDirectories() throws {
        if FileManager.default.fileExists(atPath: Self.thumbnailDirectory.path) == false {
            try FileManager.default.createDirectory(atPath: Self.thumbnailDirectory.path, withIntermediateDirectories: true)
        }
        
        if FileManager.default.fileExists(atPath: URL.tempMediaDirectory.path) == false {
            try FileManager.default.createDirectory(atPath: URL.tempMediaDirectory.path, withIntermediateDirectories: true)
        }
        
        if FileManager.default.fileExists(atPath: baseURL.path) == false {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    func driveURLForNewMedia<T: MediaDescribing>(_ media: T) -> URL {
        let filename = "\(media.id).\(media.mediaType.fileExtension)"
        return baseURL.appendingPathComponent(filename)
    }
    
    
    func previewURLForMedia<T: MediaDescribing>(_ media: T) -> URL {
        let thumbnailPath = Self.thumbnailDirectory.appendingPathComponent("\(media.id).\(MediaType.preview.fileExtension)")
        return thumbnailPath
    }
    
    func enumeratorForStorageDirectory(resourceKeys: Set<URLResourceKey> = [], fileExtensionFilter: [String]? = nil) -> [URL] {
        return Self.enumeratorForStorageDirectory(at: baseURL, resourceKeys: resourceKeys, fileExtensionFilter: fileExtensionFilter)
    }

    public func countOfFiles(matchingFileExtension: [String] = [MediaType.photo.fileExtension]) -> Int {
        let files = enumeratorForStorageDirectory(resourceKeys: Set(), fileExtensionFilter: matchingFileExtension)

        var uniqueFileNames = Set<String>()

        for file in files {
            let fileNameWithoutExtension = file.deletingPathExtension().lastPathComponent
            uniqueFileNames.insert(fileNameWithoutExtension)
        }

        return uniqueFileNames.count
    }

    public static func deletePreviewDirectory() throws {
        if FileManager.default.fileExists(atPath: thumbnailDirectory.path) == false {
            return
        }
        try FileManager.default.removeItem(at: thumbnailDirectory)
    }

    static func deleteAllFiles() throws {
        for url in enumeratorForStorageDirectory(at: Self.rootURL) {
            do {
                try FileManager.default.removeItem(at: url)
                debugPrint("Deleted item at \(url)")
            } catch {
                debugPrint("Error deleting item at \(url): ", error)
            }
        }
    }
}
