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
    var keyName: KeyName { get }
    var thumbnailDirectory: URL { get }
    var storageType: StorageType { get }
    
    init(keyName: KeyName)
    func initializeDirectories() throws
}

enum DataStorageModelError: Error {
    case noURLForiCloudDownload
    case couldNotCreateMedia
}

extension DataStorageModel {
    
    public var thumbnailDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let thumbnailDirectory = documentsDirectory.appendingPathComponent("thumbs")
        return thumbnailDirectory
    }
    
    public func initializeDirectories() throws {
        if FileManager.default.fileExists(atPath: thumbnailDirectory.path) == false {
            try FileManager.default.createDirectory(atPath: thumbnailDirectory.path, withIntermediateDirectories: true)
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
        let thumbnailPath = thumbnailDirectory.appendingPathComponent("\(media.id).\(MediaType.preview.fileExtension)")
        return thumbnailPath
    }
    
    func enumeratorForStorageDirectory(resourceKeys: Set<URLResourceKey> = [], fileExtensionFilter: [String]? = nil) -> [URL] {
        let driveUrl = baseURL
        _ = driveUrl.startAccessingSecurityScopedResource()
        
        guard let enumerator = FileManager.default.enumerator(at: driveUrl, includingPropertiesForKeys: Array(resourceKeys)) else {
            return []
        }
        driveUrl.stopAccessingSecurityScopedResource()
        let mapped = enumerator.compactMap { item -> URL? in
            guard let itemUrl = item as? URL else {
                return nil
            }
            return itemUrl
        }
        if let fileExtensionFilter = fileExtensionFilter {
            return mapped.filter({
                let components = $0.lastPathComponent.split(separator: ".")
                guard components.count > 1 else {
                    return false
                }
                
                //Account for .icloud final extension, just take the "middle" extension
                guard let fileExtension = components[safe: 1] else { return false }
                return fileExtensionFilter.contains(where: {$0.lowercased() == fileExtension})
            })
        }
        return mapped
    }
    
    public func countOfFiles(matchingFileExtension: [String] = [MediaType.photo.fileExtension]) -> Int {
        return enumeratorForStorageDirectory(resourceKeys: Set(), fileExtensionFilter: matchingFileExtension).count
    }
    
   
        
    func deleteAllFiles() throws {
        for url in enumeratorForStorageDirectory() {
            do {
                try FileManager.default.removeItem(at: url)
                debugPrint("Deleted item at \(url)")
            } catch {
                debugPrint("Error deleting item at \(url): ", error)
            }
        }
    }
}
