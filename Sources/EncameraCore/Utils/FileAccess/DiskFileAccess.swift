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



public actor DiskFileAccess: DebugPrintable {

    enum iCloudError: Error {
        case invalidURL
        case general
    }
    var key: PrivateKey?

    private var cancellables = Set<AnyCancellable>()
    private var album: Album?
    public var directoryModel: DataStorageModel?

    public init() {

    }

    public init(for album: Album, albumManager: AlbumManaging) async {
        await configure(for: album, albumManager: albumManager)
    }

    public func configure(for album: Album, albumManager: AlbumManaging) async {
        self.key = album.key
        self.album = album
        let storageModel = albumManager.storageModel(for: album)
        self.directoryModel = storageModel
        try? self.directoryModel?.initializeDirectories()
    }

    public func resolveEncryptedMedia(by id: String, type: MediaType) -> EncryptedMedia? {
        guard let url = directoryModel?.driveURLForMedia(withID: id, type: type) else {
            return nil
        }
        let media = EncryptedMedia(source: .url(url), mediaType: type, id: id)
        return media
    }

    public func enumerateMedia<T : MediaDescribing>() async -> [T] {
        guard let directoryModel = directoryModel else {
            return []
        }
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .creationDateKey])

        let filter = [MediaType.photo.encryptedFileExtension, MediaType.video.encryptedFileExtension]

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

                // First, sort by creation date
                let dateComparison = creationDate1.compare(creationDate2)
                if dateComparison != .orderedSame {
                    return dateComparison == .orderedDescending
                }

                // If dates are the same, prioritize photos over videos
                let isPhoto1 = url1.pathExtension == MediaType.photo.encryptedFileExtension
                let isPhoto2 = url2.pathExtension == MediaType.photo.encryptedFileExtension

                if isPhoto1 != isPhoto2 {
                    return isPhoto1 && !isPhoto2
                }

                // If media types are the same, sort by filename
                return url1.lastPathComponent < url2.lastPathComponent
            }.compactMap { (itemUrl: URL) in
                return T(source: .url(itemUrl), generateID: false)
            }
        return imageItems
    }

}

extension FileReader {

}


extension DiskFileAccess {

    


    public func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel  {
        guard let thumbnailPath = directoryModel?.previewURLForMedia(media) else {
            printDebug("loadMediaPreview: No thumbnail path found")
            throw FileAccessError.missingDirectoryModel
        }
        let preview = T(source: .url(thumbnailPath), mediaType: .preview, id: media.id)

        do {
            printDebug("loadMediaPreview: Trying to load thumbnail", media.id)
            let existingPreview = try await loadMediaInMemory(media: preview) { _ in }
            printDebug("loadMediaPreview: Found existing thumbnail", media.id)
            return try PreviewModel(source: existingPreview)
        } catch {
            switch media.mediaType {
            case .photo:
                printDebug("loadMediaPreview: No thumbnail found for photo with id: \(media.id)")
                return try await createPreview(for: media)
            case .video:
                // We are signaling here that there is no thumbnail for the
                // video at this time. The preview strategy should be changed
                // so that an encrypted preview is stored in a certain region
                // of the file, so we can load the preview without decrypting
                // the entire file
                printDebug("loadMediaPreview: No thumbnail found for video with id: \(media.id)")
                return try await createPreview(for: media)
            default:
                printDebug("loadMediaPreview: No thumbnail found for unknown media type")
                throw SecretFilesError.createThumbnailError
            }
        }
    }
    public func loadLeadingThumbnail() async throws -> UIImage? {
        if let album,
           let coverImageId = UserDefaultUtils.string(forKey: .albumCoverImage(albumName: album.name)) {
            if coverImageId == "none" {
                return nil
            } else if let coverImageURL = directoryModel?.driveURLForMedia(withID: coverImageId, type: .photo),
                      let preview = try? await loadMediaPreview(for: EncryptedMedia(source: .url(coverImageURL), mediaType: .photo, id: coverImageId)),
                      let previewData = preview.thumbnailMedia.data, let thumbnail = UIImage(data: previewData) {
                return thumbnail
            } else {
                return try await loadDefaultLeadingThumbnail()
            }
        } else {
            return try await loadDefaultLeadingThumbnail()
        }
    }

    public func loadMediaInMemory<T: MediaDescribing>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia {

        if var encrypted = media as? EncryptedMedia {
            if encrypted.needsDownload,
                let iCloudDirectoryModel = directoryModel as? iCloudStorageModel {
                printDebug("Downloading file from iCloud", encrypted.id)
                encrypted = try await iCloudDirectoryModel.downloadFileFromiCloud(media: encrypted) { [weak self] prog in
                    self?.printDebug("Downloading file from iCloud", encrypted.id, prog)
                    progress(.downloading(progress: prog))
                }
            }
            return try await decryptMediaToData(encrypted: encrypted, progress: progress)
        } else {
            fatalError()
        }
    }

    public func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia {
        if var encrypted = media as? EncryptedMedia {
            if encrypted.needsDownload,
                let iCloudDirectoryModel = directoryModel as? iCloudStorageModel {
                encrypted = try await iCloudDirectoryModel.downloadFileFromiCloud(media: encrypted) { prog in
                    progress(.downloading(progress: prog))
                }

            }
            return try await decryptMediaToURL(encrypted: encrypted, progress: progress)
        } else if let cleartext = media as? CleartextMedia {
            return cleartext
        }
        fatalError()
    }



    @discardableResult public func createPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel {
        do {
            let thumbnail = try await createThumbnail(for: media)
            printDebug("createPreview: Created thumbnail for \(media.id)")
            var preview = PreviewModel(thumbnailMedia: thumbnail)
            if let encrypted = media as? EncryptedMedia {
                switch encrypted.mediaType {
                case .photo:
                    break
                case .video:
                    let video: CleartextMedia = try await decryptMediaToURL(encrypted: encrypted, progress: {_ in })
                    guard let url = video.url else {
                        printDebug("createPreview: Could not get video URL")
                        throw SecretFilesError.createPreviewError
                    }
                    let asset = AVURLAsset(url: url, options: nil)
                    preview.videoDuration = asset.duration.durationText
                default:
                    printDebug("createPreview: Unknown media type")
                    throw SecretFilesError.createPreviewError
                }
            } else if let decrypted = media as? CleartextMedia, decrypted.mediaType == .video, case .url(let source) = decrypted.source {
                let asset = AVURLAsset(url: source, options: nil)
                preview.videoDuration = asset.duration.durationText
            }
            try await savePreview(preview: preview, sourceMedia: media)
            return preview

        } catch {
            printDebug("createPreview: Error creating preview for \(media.id)")
            throw error
        }

    }


    private func decryptMediaToData(encrypted: EncryptedMedia, progress: (FileLoadingStatus) -> Void) async throws -> CleartextMedia {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }
        guard case .url(_) = encrypted.source else {
            throw FileAccessError.couldNotLoadMedia
        }


        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: encrypted)

        let decrypted: CleartextMedia = try await fileHandler.decryptInMemory()
        return decrypted
    }

    private func loadDefaultLeadingThumbnail() async throws -> UIImage? {
        let media: [EncryptedMedia] = await enumerateMedia()
        guard let firstMedia = media.first else {
            return nil
        }

        do {
            let cleartextPreview = try await loadMediaPreview(for: firstMedia)
            guard let previewData = cleartextPreview.thumbnailMedia.data, let thumbnail = UIImage(data: previewData) else {
                return nil
            }
            return thumbnail

        } catch {
            return nil
        }
    }

    private func decryptMediaToURL(
        encrypted: EncryptedMedia,
        progress: @escaping (FileLoadingStatus) -> Void
    ) async throws -> CleartextMedia {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }

        guard case .url(let sourceURL) = encrypted.source else {
            printDebug("decryptMediaToURL: Could not load media")
            throw FileAccessError.couldNotLoadMedia
        }

        defer { sourceURL.stopAccessingSecurityScopedResource() }

        let targetURL = URL.tempMediaDirectory
            .appendingPathComponent(encrypted.id)
            .appendingPathExtension(encrypted.mediaType.decryptedFileExtension)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            return CleartextMedia(source: targetURL)
        }

        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: encrypted, targetURL: targetURL)

        fileHandler.progress
            .receive(on: DispatchQueue.main)
            .sink { percent in
                progress(.decrypting(progress: percent))
            }
            .store(in: &cancellables)
        let decrypted = try await fileHandler.decryptToURL()
        return decrypted

    }

    @discardableResult private func createThumbnail<T: MediaDescribing>(for media: T) async throws -> CleartextMedia {


        var thumb: CleartextMedia
        if let encrypted = media as? EncryptedMedia {

            switch encrypted.mediaType {

            case .photo:
                let decrypted: CleartextMedia = try await decryptMediaToData(encrypted: encrypted) { _ in }
                thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: decrypted)

            case .video:
                let decrypted: CleartextMedia = try await self.decryptMediaToURL(encrypted: encrypted) { _ in }
                thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: decrypted)
            default:
                throw SecretFilesError.fileTypeError
            }
        } else if let cleartext = media as? CleartextMedia {
            thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: cleartext)
        } else if let cleartext = media as? CleartextMedia {
            thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: cleartext)
        } else {
            fatalError()
        }
        return thumb
    }
}



extension DiskFileAccess {

    @discardableResult public func savePreview<T: MediaDescribing>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }
        let data = try JSONEncoder().encode(preview)
        let destinationURL = directoryModel?.previewURLForMedia(sourceMedia)
        let cleartextPreview = CleartextMedia(source: data, mediaType: .preview, id: sourceMedia.id)

        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartextPreview, targetURL: destinationURL)

        try await fileHandler.encrypt()
        printDebug("Saved preview for \(sourceMedia.id)")
        return cleartextPreview
    }

    @discardableResult public func save(media: CleartextMedia, progress: @escaping (Double) -> Void) async throws -> EncryptedMedia? {
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }
        let destinationURL = directoryModel?.driveURLForMedia(media)
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
        guard let destinationURL = directoryModel?.driveURLForMedia(media), case .url(let source) = media.source else {
            throw FileAccessError.missingDirectoryModel
        }
        try FileManager.default.copyItem(at: source, to: destinationURL)
        if let newMedia = EncryptedMedia(source: destinationURL) {
            operationBus.didCreate(newMedia)
        }
    }

    public func move(media: EncryptedMedia) async throws {
        guard let destinationURL = directoryModel?.driveURLForMedia(media), case .url(let source) = media.source else {
            throw FileAccessError.missingDirectoryModel
        }

        try FileManager.default.moveItem(at: source, to: destinationURL)
        if let newMedia = EncryptedMedia(source: destinationURL) {
            operationBus.didCreate(newMedia)
        }
    }

    public func delete(media: EncryptedMedia) async throws {
        guard case .url(let source) = media.source else {
            printDebug("Error deleting media: \(media)")
            throw FileAccessError.missingDirectoryModel
        }
        
        try FileManager.default.removeItem(at: source)
        if let previewURL = directoryModel?.previewURLForMedia(media) {
            try? FileManager.default.removeItem(at: previewURL)
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
    public static func deleteThumbnailDirectory() throws {
        try LocalStorageModel.deletePreviewDirectory()
        try iCloudStorageModel.deletePreviewDirectory()
    }

    var operationBus: FileOperationBus {
        FileOperationBus.shared
    }


}

