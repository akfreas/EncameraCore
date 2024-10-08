////
////  File.swift
////  
////
////  Created by Alexander Freas on 11.05.23.
////
//
//import Foundation
//import UIKit
//import UniformTypeIdentifiers
//
//public struct AppGroupStorageModel: DataStorageModel {
//    public static var rootURL: URL {
//        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: UserDefaultUtils.appGroup)!
//            .appendingPathComponent("ImportImages")
//    }
//
//    public var album: Album
//
//    public var baseURL: URL {
//        return Self.rootURL
//    }
//
//    public var storageType: StorageType = .local
//    
//    init?(albumManager: AlbumManaging) {
//        if let currentAlbum = albumManager.currentAlbum {
//            self.album = currentAlbum
//        } else {
//            return nil
//        }
//    }
//    
//    public init(album: Album) {
//        self.album = album
//    }
//    
//    
//}
//
//public class AppGroupFileReader: FileAccess {
//
//    
//    public var directoryModel: DataStorageModel?
//    
//    public required init() {
//        assertionFailure("Cannot use default init with this reader")
//
//    }
//
//    public required init(for album: Album, albumManager: AlbumManaging) async {
//        
//    }
//
//    public required init?(albumManager: AlbumManaging) {
//        guard let directoryModel = AppGroupStorageModel(albumManager: albumManager) else {
//            return nil
//        }
//        self.directoryModel = directoryModel
//        do {
//            try directoryModel.initializeDirectories()
//            
//        } catch {
//            assertionFailure("Directory init failed")
//        }
//    }
//    
//    public func loadLeadingThumbnail() async throws -> UIImage? {
//        let media: [CleartextMedia] = await enumerateMedia()
//        guard let first = media.first else {
//            return nil
//        }
//        let data = try await ThumbnailUtils.createThumbnailDataFrom(cleartext: first)
//        return UIImage(data: data)
//    }
//    
//    public func loadMediaPreview<T>(for media: T) async throws -> PreviewModel where T : MediaDescribing {
//        guard let cleartext = media as? CleartextMedia else {
//            throw FileAccessError.unhandledMediaType
//        }
//        let thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: cleartext)
//        let preview = PreviewModel(thumbnailMedia: thumb)
//        
//        return preview
//    }
//    
//    public func loadMediaToURL<T>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia {
//        guard let cleartext = media as? CleartextMedia else {
//            throw FileAccessError.unhandledMediaType
//        }
//        return cleartext
//    }
//    
//    public func loadMediaInMemory<T>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia where T : MediaDescribing {
//        guard let cleartext = media as? CleartextMedia, case .url(let url) = cleartext.source else {
//            throw FileAccessError.unhandledMediaType
//        }
//        let data = try Data(contentsOf: url)
//
//        return CleartextMedia(source: data)
//    }
//    
//    
//    
//}
//
//
//extension AppGroupFileReader: FileEnumerator {
//
//    public func configure(for album: Album, albumManager: AlbumManaging) async {
//        
//    }
//    
//    public func enumerateMedia<T>() async -> [T] where T : MediaDescribing {
//        guard let containerUrl = directoryModel?.baseURL else {
//            fatalError("Could not get shared container url")
//        }
//        guard T.self is CleartextMedia.Type else {
//            return []
//        }
//        
//        do {
//            let mediaFiles = try FileManager.default.contentsOfDirectory(at: containerUrl, includingPropertiesForKeys: nil, options: [])
//            
//            let filteredMediaFiles = mediaFiles.filter { MediaType.supportedMediaFileExtensions.contains($0.pathExtension.lowercased()) }
//            let mapped: [CleartextMedia] = filteredMediaFiles.map { url in
//                CleartextMedia(source: url)
//            }
//            debugPrint("Files from app group", mediaFiles, filteredMediaFiles, mapped)
//            // if there are other file types that were shared to
//            // our app group that we don't support, delete them
//            if mapped.count == 0 {
//                try await deleteAllMedia()
//            }
//            return mapped as! [T]
//        } catch {
//            debugPrint("Could not list contents of directory at url", containerUrl)
//            return []
//        }
//        
//    }
//    
//}
//
//extension AppGroupFileReader: FileWriter {
//    
//    @discardableResult public func save(media: CleartextMedia, progress: @escaping (Double) -> Void) async throws -> EncryptedMedia? {
//        if case .data(let source) = media.source, let url = directoryModel?.baseURL {
//            let filename = "\(media.id).jpeg"
//            let url = url.appendingPathComponent(filename)
//
//            print("new url", url)
//            try source.write(to: url)
//            return nil
//        } else if case .url(let url) = media.source {
//            guard let containerUrl = directoryModel?.baseURL else {
//                fatalError("Could not get shared container url")
//            }
//            
//            
//            let fileExtension = url.pathExtension
//                    .replacingOccurrences(of: "JPG", with: "jpeg")
//                    .replacingOccurrences(of: "jpg", with: "jpeg")
//            let filename = "\(media.id).\(fileExtension)"
//            let destinationURL = containerUrl.appendingPathComponent(filename)
//            debugPrint("Saving media to ", destinationURL)
//            do {
//                try FileManager.default.copyItem(at: url, to: destinationURL)
//            } catch {
//                print("Error while copying file from \(url) to \(destinationURL): \(error.localizedDescription)")
//            }
//        }
//        return nil
//    }
//    
//    public func createPreview(for media: CleartextMedia) async throws -> PreviewModel {
//        guard case .url = media.source else {
//            throw FileAccessError.unhandledMediaType
//        }
//        let thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: media)
//        return PreviewModel(thumbnailMedia: thumb)
//    }
//    
//    public func copy(media: EncryptedMedia) async throws {
//        
//    }
//    
//    public func move(media: EncryptedMedia) async throws {
//        
//    }
//    
//    public func delete(media: EncryptedMedia) async throws {
//        
//    }
//    
//    public func deleteMediaForKey() async throws {
//        
//    }
//    
//
//    
//    public func deleteAllMedia() async throws {
//        guard let containerUrl = directoryModel?.baseURL else {
//            fatalError("Could not get shared container url")
//        }
//        try? FileManager.default.removeItem(at: containerUrl)
//    }
//    
//    public static func deleteThumbnailDirectory() throws {
//        
//    }
//
//}
