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

    public var directoryModel: DataStorageModel?

    public init() {}

    public init(for album: Album, with key: PrivateKey?, albumManager: AlbumManaging) async {
        await configure(for: album, with: key, albumManager: albumManager)
    }

    public func configure(for album: Album, with key: PrivateKey?, albumManager: AlbumManaging) async {
        self.key = key
        let storageModel = albumManager.storageModel(for: album)
        self.directoryModel = storageModel
        try? self.directoryModel?.initializeDirectories()
    }


    public func enumerateMedia<T>() async -> [T] where T : MediaDescribing, T.MediaSource == URL {
        guard let directoryModel = directoryModel else {
            return []
        }
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .creationDateKey])

        let filter = [MediaType.photo.fileExtension, MediaType.video.fileExtension]

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

extension FileReader {

}


extension DiskFileAccess: FileReader {



    public func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL {
        debugPrint("loadMediaPreview: Loading preview for \(media.id)")
        guard let thumbnailPath = directoryModel?.previewURLForMedia(media) else {
            debugPrint("loadMediaPreview: No thumbnail path found")
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
                debugPrint("loadMediaPreview: No thumbnail found for video")
                throw SecretFilesError.createVideoThumbnailError
            default:
                debugPrint("loadMediaPreview: No thumbnail found for unknown media type")
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

    @discardableResult public func createPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel {

        let thumbnail = try await createThumbnail(for: media)
        debugPrint("createPreview: Created thumbnail")
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


        var thumb: CleartextMedia<Data>
        if let encrypted = media as? EncryptedMedia {

            switch encrypted.mediaType {

            case .photo:
                let decrypted: CleartextMedia<Data> = try await self.decryptMedia(encrypted: encrypted) { _ in }
                thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: decrypted)

            case .video:
                let decrypted: CleartextMedia<URL> = try await self.decryptMedia(encrypted: encrypted) { _ in }
                thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: decrypted)
            default:
                throw SecretFilesError.fileTypeError
            }
        } else if let cleartext = media as? CleartextMedia<URL> {
            thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: cleartext)
        } else if let cleartext = media as? CleartextMedia<Data> {
            thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: cleartext)
        } else {
            fatalError()
        }
        return thumb
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

    @discardableResult public func save<T: MediaSourcing>(media: CleartextMedia<T>, progress: @escaping (Double) -> Void) async throws -> EncryptedMedia? {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }
        let destinationURL = directoryModel?.driveURLForNewMedia(media)
        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: media, targetURL: destinationURL)
        fileHandler.progress
            .receive(on: DispatchQueue.main)
            .sink { percent in
                progress(percent)
            }.store(in: &cancellables)

        let encrypted = try await fileHandler.encrypt()
        try await createPreview(for: media)
        operationBus.didCreate(encrypted)
        return encrypted
    }

    public func copy(media: EncryptedMedia) async throws {
        guard let destinationURL = directoryModel?.driveURLForNewMedia(media) else {
            throw FileAccessError.missingDirectoryModel
        }
        try FileManager.default.copyItem(at: media.source, to: destinationURL)
        if let newMedia = EncryptedMedia(source: destinationURL) {
            operationBus.didCreate(newMedia)
        }
    }

    public func move(media: EncryptedMedia) async throws {
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
        for type in StorageType.allCases {
            guard case .available = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: type) else {
                continue
            }
            do {
                try type.modelForType.deleteAllFiles()
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

