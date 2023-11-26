//
//  File.swift
//  
//
//  Created by Alexander Freas on 11.05.23.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

public struct AppGroupStorageModel: DataStorageModel {
    public static var rootURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: UserDefaultUtils.appGroup)!
            .appendingPathComponent("ImportImages")
    }

    public var album: Album

    public var baseURL: URL {
        return Self.rootURL
    }

    public var storageType: StorageType = .local
    
    init() {
        self.album = Album(name: "", storageOption: .local, creationDate: Date())
    }
    
    public init(album: Album) {
        self.album = album
    }
    
    
}

public class AppGroupFileReader: FileAccess {

    
    public var directoryModel: DataStorageModel? = AppGroupStorageModel()
    
   
    public required init() {
        do {
            try directoryModel?.initializeDirectories()
            
        } catch {
            assertionFailure("Directory init failed")
        }
    }
    
    public func loadLeadingThumbnail() async throws -> UIImage? {
        let media: [CleartextMedia<URL>] = await enumerateMedia()
        guard let first = media.first else {
            return nil
        }
        let data = try await ThumbnailUtils.createThumbnailDataFrom(cleartext: first)
        return UIImage(data: data)
    }
    
    public func loadMediaPreview<T>(for media: T) async throws -> PreviewModel where T : MediaDescribing, T.MediaSource == URL {
        guard let cleartext = media as? CleartextMedia<URL> else {
            throw FileAccessError.unhandledMediaType
        }
        let thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: cleartext)
        let preview = PreviewModel(thumbnailMedia: thumb)
        
        return preview
    }
    
    public func loadMediaToURL<T>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL> where T : MediaDescribing {
        guard let cleartext = media as? CleartextMedia<URL> else {
            throw FileAccessError.unhandledMediaType
        }
        return cleartext
    }
    
    public func loadMediaInMemory<T>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        guard let cleartext = media as? CleartextMedia<URL> else {
            throw FileAccessError.unhandledMediaType
        }
        let data = try Data(contentsOf: cleartext.source)
        
        return CleartextMedia(source: data)
    }
    
    
    
}


extension AppGroupFileReader: FileEnumerator {

    public func configure(for album: Album, with key: PrivateKey?, albumManager: AlbumManaging) async {
        
    }
    
    public func enumerateMedia<T>() async -> [T] where T : MediaDescribing, T.MediaSource == URL {
        guard let containerUrl = directoryModel?.baseURL else {
            fatalError("Could not get shared container url")
        }
        guard T.self is CleartextMedia<URL>.Type else {
            return []
        }
        
        do {
            let mediaFiles = try FileManager.default.contentsOfDirectory(at: containerUrl, includingPropertiesForKeys: nil, options: [])
            
            let filteredMediaFiles = mediaFiles.filter { MediaType.supportedMediaFileExtensions.contains($0.pathExtension.lowercased()) }
            let mapped: [CleartextMedia<URL>] = filteredMediaFiles.map { url in
                CleartextMedia(source: url)
            }
            debugPrint("Files from app group", mediaFiles, filteredMediaFiles, mapped)
            // if there are other file types that were shared to
            // our app group that we don't support, delete them
            if mapped.count == 0 {
                try await deleteAllMedia()
            }
            return mapped as! [T]
        } catch {
            debugPrint("Could not list contents of directory at url", containerUrl)
            return []
        }
        
    }
    
}

extension AppGroupFileReader: FileWriter {
    
    @discardableResult public func save<T>(media: CleartextMedia<T>, progress: @escaping (Double) -> Void) async throws -> EncryptedMedia? where T : MediaSourcing {
        if let cleartext = media as? CleartextMedia<Data>, let url = directoryModel?.baseURL {
            let filename = "\(media.id).jpeg"
            let url = url.appendingPathComponent(filename)

            print("new url", url)
            try cleartext.source.write(to: url)
            return nil
        } else if let cleartext = media as? CleartextMedia<URL> {
            let url = cleartext.source
            guard let containerUrl = directoryModel?.baseURL else {
                fatalError("Could not get shared container url")
            }
            
            
            let fileExtension = url.pathExtension
                    .replacingOccurrences(of: "JPG", with: "jpeg")
                    .replacingOccurrences(of: "jpg", with: "jpeg")
            let filename = "\(cleartext.id).\(fileExtension)"
            let destinationURL = containerUrl.appendingPathComponent(filename)
            debugPrint("Saving media to ", destinationURL)
            do {
                try FileManager.default.copyItem(at: url, to: destinationURL)
            } catch {
                print("Error while copying file from \(url) to \(destinationURL): \(error.localizedDescription)")
            }
        }
        return nil
    }
    
    public func createPreview<T>(for media: T) async throws -> PreviewModel where T : MediaDescribing {
        guard let cleartext = media as? CleartextMedia<URL> else {
            throw FileAccessError.unhandledMediaType
        }
        let thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: cleartext)
        return PreviewModel(thumbnailMedia: thumb)
    }
    
    public func copy(media: EncryptedMedia) async throws {
        
    }
    
    public func move(media: EncryptedMedia) async throws {
        
    }
    
    public func delete(media: EncryptedMedia) async throws {
        
    }
    
    public func deleteMediaForKey() async throws {
        
    }
    
    public func moveAllMedia(for keyName: KeyName, toRenamedKey newKeyName: KeyName) async throws {
        
    }
    
    public func deleteAllMedia() async throws {
        guard let containerUrl = directoryModel?.baseURL else {
            fatalError("Could not get shared container url")
        }
        try? FileManager.default.removeItem(at: containerUrl)
    }
    
    
}
