//
//  File.swift
//  
//
//  Created by Alexander Freas on 17.07.24.
//

import Foundation
import UIKit

public actor InteractableMediaDiskAccess: FileAccess {
    public init() {
        fatalError()
    }


    private var fileAccess: DiskFileAccess

    public init(for album: Album, albumManager: AlbumManaging) async {
        await self.fileAccess = DiskFileAccess(for: album, albumManager: albumManager)
    }


    public func configure(for album: Album, albumManager: AlbumManaging) async {
        await fileAccess.configure(for: album, albumManager: albumManager)
    }
    
    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T : MediaDescribing {
        let media: [T] = await fileAccess.enumerateMedia()

        var mediaMap = [String: InteractableMedia<T>]()

        for mediaItem in media {
            do {
                if var interactableMedia = mediaMap[mediaItem.id] {
                    interactableMedia.underlyingMedia.append(mediaItem)
                    continue
                } else {
                    let interactableMedia = try InteractableMedia(underlyingMedia: [mediaItem])
                    mediaMap[interactableMedia.id] = interactableMedia
                }
            } catch {
                debugPrint("Could not create interactable media: \(error)")
            }
        }
        return Array(mediaMap.values)
    }
    




    public func loadLeadingThumbnail() async throws -> UIImage? {
        return try await fileAccess.loadLeadingThumbnail()
    }
    
    public func loadMediaPreview<T>(for media: InteractableMedia<T>) async throws -> PreviewModel where T : MediaDescribing {
        return try await fileAccess.loadMediaPreview(for: media.thumbnailSource)
    }
    
    public func loadMediaToURL<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T : MediaDescribing {
        var decrypted: [CleartextMedia] = []
        for mediaItem in media.underlyingMedia {
            let cleartextMedia = try await fileAccess.loadMediaToURL(media: mediaItem, progress: progress)
            decrypted.append(cleartextMedia)
        }

        return try InteractableMedia(underlyingMedia: decrypted)
    }
    
    public func loadMediaInMemory(media: InteractableMedia<EncryptedMedia>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> {
        var decrypted: [CleartextMedia] = []
        for mediaItem in media.underlyingMedia {
            let cleartextMedia = try await fileAccess.loadMediaInMemory(media: mediaItem, progress: progress)
            decrypted.append(cleartextMedia)
        }

        return try InteractableMedia(underlyingMedia: decrypted)
    }
    

    public func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        var encrypted: [EncryptedMedia] = []
        for mediaItem in media.underlyingMedia {
            if let encryptedMedia = try await fileAccess.save(media: mediaItem, progress: progress) {
                encrypted.append(encryptedMedia)
            }
        }

        return try InteractableMedia(underlyingMedia: encrypted)
    }
    
    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        return try await fileAccess.createPreview(for: media.thumbnailSource)
    }
    
    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        for mediaItem in media.underlyingMedia {
            try await fileAccess.copy(media: mediaItem)
        }
    }
    
    public func move(media: InteractableMedia<EncryptedMedia>) async throws {
        for mediaItem in media.underlyingMedia {
            try await fileAccess.move(media: mediaItem)
        }
    }
    
    public func delete(media: InteractableMedia<EncryptedMedia>) async throws {
        for mediaItem in media.underlyingMedia {
            try await fileAccess.delete(media: mediaItem)
        }
    }
    
    public func deleteMediaForKey() async throws {
        try await fileAccess.deleteMediaForKey()
    }
        
    public func deleteAllMedia() async throws {
        try await fileAccess.deleteAllMedia()
    }
    
    public static func deleteThumbnailDirectory() throws {
        try DiskFileAccess.deleteThumbnailDirectory()
    }
}


