//  Created by Alexander Freas on 17.07.24.
//

import Foundation
import UIKit

public actor InteractableMediaDiskAccess: FileAccess {
    public init() {
        fileAccess = DiskFileAccess()
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
                if let interactableMedia = mediaMap[mediaItem.id] {
                    interactableMedia.appendToUnderlyingMedia(media: mediaItem)
                    continue
                } else {
                    let interactableMedia = try InteractableMedia(underlyingMedia: [mediaItem])
                    mediaMap[interactableMedia.id] = interactableMedia
                }
            } catch {
                debugPrint("Could not create interactable media: \(error)")
            }
        }
        let sortedByDateDesc = Array(mediaMap.values).sorted { media1, media2 in
            guard let timestamp1 = media1.timestamp, let timestamp2 = media2.timestamp else {
                return false
            }
            return timestamp1.compare(timestamp2) == .orderedDescending
        }
        return sortedByDateDesc
    }
    




    public func loadLeadingThumbnail() async throws -> UIImage? {
        return try await fileAccess.loadLeadingThumbnail()
    }
    
    public func loadMediaPreview<T>(for media: InteractableMedia<T>) async throws -> PreviewModel where T : MediaDescribing {
        var preview = try await fileAccess.loadMediaPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    public func loadMediaToURLs(
        media: InteractableMedia<EncryptedMedia>,
        progress: @escaping (FileLoadingStatus) -> Void) async throws -> [URL] {
        var urls = [URL]()
        for mediaItem in media.underlyingMedia {

            let loaded = try await fileAccess.loadMediaToURL(media: mediaItem, progress: progress)
            guard let url = loaded.url else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    public func loadMedia<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T : MediaDescribing {
        var decrypted: [CleartextMedia] = []
        for mediaItem in media.underlyingMedia {
            if mediaItem.mediaType == .photo {
                let cleartextMedia = try await fileAccess.loadMediaInMemory(media: mediaItem, progress: progress)
                decrypted.append(cleartextMedia)
            } else if mediaItem.mediaType == .video {
                let cleartextMedia = try await fileAccess.loadMediaToURL(media: mediaItem, progress: progress)
                decrypted.append(cleartextMedia)
            }
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
        var preview = try await fileAccess.createPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
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


