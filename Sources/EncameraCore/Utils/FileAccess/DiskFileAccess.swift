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



/// Thread-safe wrapper for caching PreviewModel in NSCache.
private final class PreviewModelWrapper: NSObject {
    let preview: PreviewModel
    init(_ preview: PreviewModel) { self.preview = preview }
}

public actor DiskFileAccess: DebugPrintable {

    /// Limits concurrent preview generation to avoid memory spikes from accumulated decrypted data.
    private static let previewSemaphore = AsyncSemaphore(value: 5)

    /// In-memory cache for decrypted preview thumbnails. NSCache is thread-safe,
    /// so it can be accessed outside actor isolation. Auto-evicts under memory pressure.
    private static let previewCache: NSCache<NSString, PreviewModelWrapper> = {
        let cache = NSCache<NSString, PreviewModelWrapper>()
        cache.countLimit = 200
        return cache
    }()

    enum iCloudError: Error {
        case invalidURL
        case general
    }
    var key: PrivateKey?

    /// Per-process discovery memo: media id → resolved key uuid. The stamp is
    /// the durable cache for local files, but iCloud files never get stamped,
    /// so without this every open of an unstamped iCloud file would re-run
    /// the full discovery sweep. Process-lifetime only and unbounded on
    /// purpose: ~50 bytes/entry is low single-digit MBs even at 100k items,
    /// so no LRU machinery is warranted.
    private var discoveredKeyMemo: [String: UUID] = [:]

    /// Short-lived snapshot of the key library, so sweeping an album costs one
    /// keychain query rather than one per image.
    ///
    /// `KeychainManager.storedKeys()` is a `SecItemCopyMatching` over every
    /// stored key with `kSecReturnData`, and `resolveKey` runs per file. On an
    /// iPhone 12 Pro holding one key that measured ~0.39ms per call — ~47ms of
    /// pure keychain traffic for a 120-image album, growing with the library and
    /// repeated on every re-entry into an album whose key is missing.
    ///
    /// The TTL bounds staleness the app cannot see coming: the key library also
    /// changes from OUTSIDE this process — iCloud Keychain sync adds and
    /// tombstones items with no local call to hook, which is precisely what the
    /// two-device suites exercise — so no set of local invalidation points is
    /// complete on its own.
    ///
    /// The one change that must NOT wait out the TTL is a key being added to fix
    /// exactly the media being looked at (ENC-99): the user types a phrase and
    /// expects the album to open. That posts `.keyLibraryDidGrow`, which bumps
    /// `storedKeysGeneration` below and retires every outstanding snapshot at
    /// once, so the re-enumerate that follows always reads the grown library.
    private var storedKeysSnapshot: (keys: [PrivateKey], readAt: Date, generation: UInt64)?

    /// Long enough to collapse one album sweep (~100ms for 120 images), short
    /// enough that a key arriving over iCloud shows up effectively immediately.
    ///
    /// Settable so tests that assert on keychain call counts can zero it and go
    /// on measuring what they were written to measure, rather than being
    /// silently weakened into passing by the cache.
    static var storedKeysSnapshotTTL: TimeInterval = 1.0

    /// Bumped on `.keyLibraryDidGrow`; a snapshot from an older generation is
    /// never reused. Static and observed once for the process, so this works for
    /// every `DiskFileAccess` instance without per-instance wiring.
    private static let storedKeysGenerationLock = NSLock()
    nonisolated(unsafe) private static var storedKeysGenerationValue: UInt64 = 0
    private static var storedKeysGeneration: UInt64 {
        storedKeysGenerationLock.lock()
        defer { storedKeysGenerationLock.unlock() }
        return storedKeysGenerationValue
    }
    private static let keyLibraryGrowthObserver: Void = {
        NotificationCenter.default.addObserver(
            forName: .keyLibraryDidGrow, object: nil, queue: nil
        ) { _ in
            storedKeysGenerationLock.lock()
            storedKeysGenerationValue &+= 1
            storedKeysGenerationLock.unlock()
        }
    }()

    /// The key library, re-reading it only once per `storedKeysSnapshotTTL` and
    /// never across a `.keyLibraryDidGrow`.
    private func currentStoredKeys(_ keyManager: KeyManager) -> [PrivateKey] {
        _ = Self.keyLibraryGrowthObserver
        let generation = Self.storedKeysGeneration
        if let snapshot = storedKeysSnapshot,
           snapshot.generation == generation,
           Date().timeIntervalSince(snapshot.readAt) < Self.storedKeysSnapshotTTL {
            return snapshot.keys
        }
        let keys = (try? keyManager.storedKeys()) ?? []
        storedKeysSnapshot = (keys, Date(), generation)
        return keys
    }

    private var cancellables = Set<AnyCancellable>()
    private var album: Album?
    public var directoryModel: DataStorageModel?
    private var keyManager: KeyManager?
    private var albumManager: AlbumManaging?

    public init() {

    }

    public init(for album: Album, albumManager: AlbumManaging) async {
        await configure(for: album, albumManager: albumManager)
    }

    public func configure(for album: Album, albumManager: AlbumManaging) async {
        self.key = album.key
        self.album = album
        self.keyManager = albumManager.keyManager
        self.albumManager = albumManager
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

        let urls: [URL] = directoryModel.enumeratorForStorageDirectory(
            resourceKeys: Self.enumerationResourceKeys,
            fileExtensionFilter: Self.mediaFileExtensionFilter
        )

        return Self.sortedMediaURLs(urls).compactMap { itemURL in
            T(source: .url(itemURL), generateID: false)
        }
    }

    /// Enumerates all encrypted media files across all albums in both local and iCloud storage
    /// This is like running a `find` command at the base storage directories
    public func enumerateAllMedia<T: MediaDescribing>() async -> [T] {
        var allURLs: [URL] = []

        // Enumerate local storage (both locations to handle partial migration)
        allURLs.append(contentsOf: LocalStorageModel.enumeratorForStorageDirectory(
            at: LocalStorageModel.albumsURL,
            resourceKeys: Self.enumerationResourceKeys,
            fileExtensionFilter: Self.mediaFileExtensionFilter
        ))
        allURLs.append(contentsOf: LocalStorageModel.enumeratorForStorageDirectory(
            at: LocalStorageModel.rootURL,
            resourceKeys: Self.enumerationResourceKeys,
            fileExtensionFilter: Self.mediaFileExtensionFilter
        ))

        // Enumerate iCloud storage if available (both locations to handle partial migration)
        if case .available = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) {
            allURLs.append(contentsOf: iCloudStorageModel.enumeratorForStorageDirectory(
                at: iCloudStorageModel.albumsURL,
                resourceKeys: Self.enumerationResourceKeys,
                fileExtensionFilter: Self.mediaFileExtensionFilter
            ))
            allURLs.append(contentsOf: iCloudStorageModel.enumeratorForStorageDirectory(
                at: iCloudStorageModel.rootURL,
                resourceKeys: Self.enumerationResourceKeys,
                fileExtensionFilter: Self.mediaFileExtensionFilter
            ))
        }

        return Self.sortedMediaURLs(allURLs).compactMap { itemURL in
            T(source: .url(itemURL), generateID: false)
        }
    }

    // MARK: - Media URL Sorting

    /// Resource keys prefetched by `contentsOfDirectory` so `sortedMediaURLs`
    /// can read creation dates from cache instead of issuing fresh `stat` calls.
    private static let enumerationResourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .creationDateKey])

    private static let mediaFileExtensionFilter = [
        MediaType.photo.encryptedFileExtension,
        MediaType.video.encryptedFileExtension
    ]

    /// Pre-fetched per-file info, read once so the sort comparator never
    /// re-touches the filesystem.
    private struct SortableMediaURL {
        let url: URL
        let creationDate: Date
        let isPhoto: Bool
        let name: String
    }

    /// Sorts media URLs newest-first. Reads each URL's creation date exactly
    /// once — the value is already prefetched by `contentsOfDirectory` — instead
    /// of the O(n log n) `resourceValues` calls a comparator-based sort makes.
    /// Ties break photos before videos, then by filename.
    private static func sortedMediaURLs(_ urls: [URL]) -> [URL] {
        let photoExtension = MediaType.photo.encryptedFileExtension
        let entries: [SortableMediaURL] = urls.map { url in
            let creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            return SortableMediaURL(
                url: url,
                creationDate: creationDate ?? .distantPast,
                isPhoto: url.pathExtension == photoExtension,
                name: url.lastPathComponent
            )
        }

        return entries.sorted { lhs, rhs in
            let dateComparison = lhs.creationDate.compare(rhs.creationDate)
            if dateComparison != .orderedSame {
                return dateComparison == .orderedDescending
            }
            if lhs.isPhoto != rhs.isPhoto {
                return lhs.isPhoto
            }
            return lhs.name < rhs.name
        }.map { $0.url }
    }

    public func totalStoredMediaCount() async -> Int {
        let extensions = Set([MediaType.photo.encryptedFileExtension, MediaType.video.encryptedFileExtension])
        let maxDepth = 10
        var count = 0
        var countedMediaIDs = Set<String>()

        func collectMediaCount(at rootURL: URL) {
            _ = rootURL.startAccessingSecurityScopedResource()
            defer { rootURL.stopAccessingSecurityScopedResource() }

            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: []
            ) else { return }

            for case let fileURL as URL in enumerator {
                if enumerator.level > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }

                // Skip directories that don't contain user media
                let name = fileURL.lastPathComponent
                if name == ".Trash" || name == AppConstants.previewDirectory || name == "thumbs" {
                    enumerator.skipDescendants()
                    continue
                }

                // Match extensions using the same logic as enumeratorForStorageDirectory,
                // accounting for .icloud placeholder files (e.g. uuid.enc_photo.icloud)
                let components = name.split(separator: ".")
                guard components.count > 1,
                      let fileExtension = components[safe: 1],
                      extensions.contains(where: { $0.lowercased() == fileExtension.lowercased() }) else {
                    continue
                }

                let mediaID = String(components[0])
                if !mediaID.isEmpty, countedMediaIDs.insert(mediaID).inserted {
                    count += 1
                }
            }
        }

        collectMediaCount(at: LocalStorageModel.albumsURL)
        collectMediaCount(at: LocalStorageModel.rootURL)

        if case .available = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) {
            collectMediaCount(at: iCloudStorageModel.albumsURL)
            collectMediaCount(at: iCloudStorageModel.rootURL)
        }

        return count
    }

    /// Enumerates all preview files across all storage types
    private func enumerateAllPreviewFiles() -> [URL] {
        var allPreviewFiles: [URL] = []
        
        // Get preview files from local storage
        let localPreviewFiles = LocalStorageModel.enumeratorForStorageDirectory(
            at: LocalStorageModel.thumbnailDirectory,
            fileExtensionFilter: [MediaType.preview.encryptedFileExtension]
        )
        allPreviewFiles.append(contentsOf: localPreviewFiles)
        
        // Get preview files from iCloud storage if available
        if case .available = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) {
            let iCloudPreviewFiles = iCloudStorageModel.enumeratorForStorageDirectory(
                at: iCloudStorageModel.thumbnailDirectory,
                fileExtensionFilter: [MediaType.preview.encryptedFileExtension]
            )
            allPreviewFiles.append(contentsOf: iCloudPreviewFiles)
        }
        
        return allPreviewFiles
    }
    
    // MARK: - Metadata Extraction Helpers
    
    /// Extracts metadata info for a single media item
    /// For V2 files, reads embedded metadata. For V1 files, uses file system dates and extension-based type detection.
    /// - Parameters:
    ///   - media: The encrypted media to extract metadata for
    ///   - v2Metadata: Pre-loaded V2 metadata (nil for V1 files)
    /// - Returns: Tuple containing extracted dates and media subtype
    private func extractMetadataInfo(
        for media: EncryptedMedia,
        v2Metadata: EncryptedFileMetadata?
    ) -> (dateTaken: Date?, dateEncrypted: Date?, subtype: MediaFilterOptions) {
        
        if let metadata = v2Metadata {
            // V2 file - use embedded metadata
            let dateTaken = metadata.captureDate
            let dateEncrypted = metadata.encryptionDate
            
            // Determine media subtype from V2 metadata
            // Live Photos are treated as still images for filtering purposes
            let subtype: MediaFilterOptions
            if metadata.contentAnalysis?.isLivePhoto == true || metadata.originalMediaType == "livePhoto" {
                subtype = .stillImage
            } else if metadata.originalMediaType == "video" {
                subtype = .video
            } else if metadata.contentAnalysis?.isScreenshot == true {
                subtype = .screenshot
            } else {
                subtype = .stillImage
            }
            
            return (dateTaken, dateEncrypted, subtype)
        } else {
            // V1 file - fall back to file system dates
            var dateTaken: Date?
            var dateEncrypted: Date?
            
            if case .url(let url) = media.source {
                let resourceKeys: Set<URLResourceKey> = [.creationDateKey]
                if let values = try? url.resourceValues(forKeys: resourceKeys) {
                    let creationDate = values.creationDate
                    dateTaken = creationDate
                    dateEncrypted = creationDate
                }
            }
            
            // V1 media subtype detection from file extension only
            let subtype: MediaFilterOptions
            switch media.mediaType {
            case .video:
                subtype = .video
            case .photo:
                // Cannot detect live photos or screenshots for V1 files
                subtype = .stillImage
            default:
                subtype = .stillImage
            }
            
            return (dateTaken, dateEncrypted, subtype)
        }
    }
    
    // MARK: - Enumeration with Metadata
    
    /// Enumerates encrypted media with metadata for sorting and filtering
    /// This is the low-level implementation used by InteractableMediaFileAccess
    /// - Parameters:
    ///   - sortOption: How to sort results (default: dateEncrypted descending)
    ///   - filterOptions: Media subtypes to include (default: all)
    /// - Returns: Array of MediaWithMetadata containing media and extracted metadata
    public func enumerateEncryptedMediaWithMetadata(
        sortBy sortOption: MediaSortOption = .dateEncrypted(ascending: false),
        filterBy filterOptions: MediaFilterOptions = .all
    ) async -> [MediaWithMetadata<EncryptedMedia>] {
        
        // Get all encrypted media
        let allMedia: [EncryptedMedia] = await enumerateMedia()
        
        guard !allMedia.isEmpty else {
            return []
        }
        
        // Get key bytes for metadata decryption
        guard let keyBytes = key?.keyBytes else {
            printDebug("enumerateEncryptedMediaWithMetadata: No key available, using file system fallback for all files")
            // Fall back to file system dates for all files
            return buildMediaWithMetadataArray(
                media: allMedia,
                metadataMap: [:],
                sortOption: sortOption,
                filterOptions: filterOptions
            )
        }
        
        // Extract URLs for batch metadata reading
        let urls: [URL] = allMedia.compactMap { media in
            if case .url(let url) = media.source {
                return url
            }
            return nil
        }
        
        // Batch read V2 metadata
        let metadataHandler = EncryptedMetadataHandler()
        let metadataResults = await metadataHandler.readMetadataBatch(from: urls, keyBytes: keyBytes)
        
        // Build URL to metadata map
        var metadataMap: [URL: EncryptedFileMetadata] = [:]
        for (url, metadata) in metadataResults {
            if let metadata = metadata {
                metadataMap[url] = metadata
            }
        }
        
        return buildMediaWithMetadataArray(
            media: allMedia,
            metadataMap: metadataMap,
            sortOption: sortOption,
            filterOptions: filterOptions
        )
    }
    
    /// Reads metadata for a specific set of media rather than the whole album.
    /// Used for incremental index updates so only newly-added files are opened
    /// and decrypted. Returned items are unsorted and unfiltered.
    /// - Parameter onProgress: Optional `(completed, total)` callback forwarded
    ///   to the underlying metadata batch read, for driving a progress bar.
    public func encryptedMediaWithMetadata(
        for media: [EncryptedMedia],
        onProgress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async -> [MediaWithMetadata<EncryptedMedia>] {
        guard !media.isEmpty else { return [] }

        guard let keyBytes = key?.keyBytes else {
            return buildMediaWithMetadataArray(
                media: media,
                metadataMap: [:],
                sortOption: .dateEncrypted(ascending: false),
                filterOptions: .all
            )
        }

        let urls: [URL] = media.compactMap { item in
            if case .url(let url) = item.source { return url }
            return nil
        }
        let metadataHandler = EncryptedMetadataHandler()
        let metadataResults = await metadataHandler.readMetadataBatch(
            from: urls,
            keyBytes: keyBytes,
            onProgress: onProgress
        )

        var metadataMap: [URL: EncryptedFileMetadata] = [:]
        for (url, metadata) in metadataResults {
            if let metadata = metadata {
                metadataMap[url] = metadata
            }
        }

        return buildMediaWithMetadataArray(
            media: media,
            metadataMap: metadataMap,
            sortOption: .dateEncrypted(ascending: false),
            filterOptions: .all
        )
    }

    /// Builds the MediaWithMetadata array with filtering and sorting applied
    private func buildMediaWithMetadataArray(
        media: [EncryptedMedia],
        metadataMap: [URL: EncryptedFileMetadata],
        sortOption: MediaSortOption,
        filterOptions: MediaFilterOptions
    ) -> [MediaWithMetadata<EncryptedMedia>] {

        // First pass: identify IDs of Live Photo components so their video
        // counterparts can also be treated as still images for filtering
        var livePhotoIDs: Set<String> = []
        for mediaItem in media {
            var v2Metadata: EncryptedFileMetadata?
            if case .url(let url) = mediaItem.source {
                v2Metadata = metadataMap[url]
            }
            if let metadata = v2Metadata,
               metadata.contentAnalysis?.isLivePhoto == true || metadata.originalMediaType == "livePhoto" {
                livePhotoIDs.insert(mediaItem.id)
            }
        }

        // Second pass: build MediaWithMetadata for each item
        var results: [MediaWithMetadata<EncryptedMedia>] = []

        for mediaItem in media {
            // Get V2 metadata if available
            var v2Metadata: EncryptedFileMetadata?
            if case .url(let url) = mediaItem.source {
                v2Metadata = metadataMap[url]
            }

            // Extract metadata info (handles V1/V2 fallback)
            var (dateTaken, dateEncrypted, subtype) = extractMetadataInfo(
                for: mediaItem,
                v2Metadata: v2Metadata
            )

            // Reclassify video components of Live Photos as still images
            // so they are filtered together with their photo counterpart
            if subtype == .video && livePhotoIDs.contains(mediaItem.id) {
                subtype = .stillImage
            }

            // Apply filter
            if !filterOptions.contains(subtype) {
                continue
            }

            let wrapper = MediaWithMetadata(
                media: mediaItem,
                metadata: v2Metadata,
                dateTaken: dateTaken,
                dateEncrypted: dateEncrypted,
                mediaSubtype: subtype
            )
            results.append(wrapper)
        }
        
        // Apply sorting
        results.sort { item1, item2 in
            switch sortOption {
            case .dateTaken(let ascending):
                guard let date1 = item1.dateTaken, let date2 = item2.dateTaken else {
                    // Items without dates go to the end
                    if item1.dateTaken == nil && item2.dateTaken == nil {
                        return false
                    }
                    return item1.dateTaken != nil
                }
                return ascending ? date1 < date2 : date1 > date2
                
            case .dateEncrypted(let ascending):
                guard let date1 = item1.dateEncrypted, let date2 = item2.dateEncrypted else {
                    // Items without dates go to the end
                    if item1.dateEncrypted == nil && item2.dateEncrypted == nil {
                        return false
                    }
                    return item1.dateEncrypted != nil
                }
                return ascending ? date1 < date2 : date1 > date2
            }
        }
        
        return results
    }

}

extension FileReader {

}


extension DiskFileAccess {

    


    public func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel  {
        let cacheKey = media.id as NSString
        if let cached = Self.previewCache.object(forKey: cacheKey) {
            return cached.preview
        }

        guard let thumbnailPath = directoryModel?.previewURLForMedia(media) else {
            printDebug("loadMediaPreview: No thumbnail path found")
            throw FileAccessError.missingDirectoryModel
        }
        let preview = T(source: .url(thumbnailPath), mediaType: .preview, id: media.id)

        let result: PreviewModel
        do {
            printDebug("loadMediaPreview: Trying to load thumbnail", media.id)
            let existingPreview = try await loadMediaInMemory(media: preview) { _ in }
            printDebug("loadMediaPreview: Found existing thumbnail", media.id)
            result = try PreviewModel(source: existingPreview)
        } catch {
            // "The thumbnail needs a key we do not have" is an answer, not a
            // miss. Regenerating the preview decrypts the SAME media with the
            // SAME key, so it cannot succeed — and when the media itself is not
            // on this device (a CloudKit second device, the exact case ENC-99
            // exists for) `createPreview` fails through the `.unreadable`
            // current-key fallback and reports a generic `decryptError`, which
            // destroys the one actionable signal the user could have acted on.
            // Observed on the rig: every item in a materialized album showed the
            // generic failure glyph instead of the missing-key state.
            if case FileAccessError.missingKeyForMedia = error {
                printDebug("loadMediaPreview: thumbnail needs an absent key for \(media.id)")
                throw error
            }
            switch media.mediaType {
            case .photo:
                printDebug("loadMediaPreview: No thumbnail found for photo with id: \(media.id)")
                result = try await createPreview(for: media)
            case .video:
                printDebug("loadMediaPreview: No thumbnail found for video with id: \(media.id)")
                result = try await createPreview(for: media)
            default:
                printDebug("loadMediaPreview: No thumbnail found for unknown media type")
                throw SecretFilesError.createThumbnailError
            }
        }
        Self.previewCache.setObject(PreviewModelWrapper(result), forKey: cacheKey)
        return result
    }
    public func loadLeadingThumbnail(purchasedPermissions: (any PurchasedPermissionManaging)? = nil) async throws -> UIImage? {
        if let album,
           let albumManager = albumManager,
           let coverImageId = albumManager.getAlbumCoverImageId(album: album) {
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
            // Check if file needs to be downloaded from iCloud
            encrypted = try await ensureFileIsDownloaded(encrypted: encrypted, progress: progress)
            return try await decryptMediaToData(encrypted: encrypted, progress: progress)
        } else {
            fatalError()
        }
    }
    
    /// Ensures the file is downloaded from iCloud if needed
    /// Works regardless of the current directoryModel type by checking the actual file status
    private func ensureFileIsDownloaded(encrypted: EncryptedMedia, progress: @escaping (FileLoadingStatus) -> Void) async throws -> EncryptedMedia {
        guard case .url(let sourceURL) = encrypted.source else {
            return encrypted
        }

        // Get comprehensive iCloud status
        let status = iCloudFileStatusUtil.getStatus(for: sourceURL)

        // If file is not a ubiquitous item or is already downloaded, proceed
        guard status.isUbiquitousItem else {
            return encrypted
        }

        switch status.downloadState {
        case .current:
            // File is fully downloaded
            return encrypted
            
        case .notDownloaded:
            // File needs to be downloaded
            printDebug("File needs download from iCloud", encrypted.id)
            progress(.downloading(progress: 0))
            
            // If we have an iCloud directory model, use its download method
            if let iCloudDirectoryModel = directoryModel as? iCloudStorageModel {
                let downloaded = try await iCloudDirectoryModel.downloadFileFromiCloud(media: encrypted) { [weak self] prog in
                    self?.printDebug("Downloading file from iCloud", encrypted.id, prog)
                    progress(.downloading(progress: prog))
                }
                return downloaded
            } else {
                // The file is in iCloud but our directoryModel is not iCloud
                // This can happen in edge cases - trigger download and wait
                printDebug("File is in iCloud but directoryModel is not iCloudStorageModel, triggering download", encrypted.id)
                try iCloudFileStatusUtil.startDownload(for: sourceURL)
                
                // Wait for the download to complete with polling
                let downloaded = try await waitForICloudDownload(media: encrypted, progress: progress)
                return downloaded
            }
            
        case .downloading(let downloadProgress):
            // Download is already in progress, wait for it to complete
            printDebug("File is currently downloading from iCloud, waiting", encrypted.id, downloadProgress)
            progress(.downloading(progress: downloadProgress / 100.0))
            let downloaded = try await waitForICloudDownload(media: encrypted, progress: progress)
            return downloaded
            
        case .downloadFailed:
            // Previous download failed, retry
            printDebug("Previous iCloud download failed, retrying", encrypted.id)
            progress(.downloading(progress: 0))
            try iCloudFileStatusUtil.startDownload(for: sourceURL)
            let downloaded = try await waitForICloudDownload(media: encrypted, progress: progress)
            return downloaded
            
        case .notUbiquitous:
            // Not an iCloud file, should have been caught above
            return encrypted
        }
    }

    public func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia {
        if var encrypted = media as? EncryptedMedia {
            // Check if file needs to be downloaded from iCloud
            encrypted = try await ensureFileIsDownloaded(encrypted: encrypted, progress: progress)
            return try await decryptMediaToURL(encrypted: encrypted, progress: progress)
        } else if let cleartext = media as? CleartextMedia {
            return cleartext
        }
        fatalError()
    }



    @discardableResult public func createPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel {
        try Task.checkCancellation()
        await Self.previewSemaphore.wait()
        defer { Task { await Self.previewSemaphore.signal() } }
        try Task.checkCancellation()

        do {
            var preview: PreviewModel

            if let encrypted = media as? EncryptedMedia, encrypted.mediaType == .video {
                // === Video: single decryption, extract both thumbnail and duration ===
                let decrypted: CleartextMedia = try await decryptMediaToURL(encrypted: encrypted, progress: { _ in })
                guard let url = decrypted.url else {
                    printDebug("createPreview: Could not get video URL")
                    throw SecretFilesError.createPreviewError
                }
                let thumb = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: decrypted)
                preview = PreviewModel(thumbnailMedia: thumb)
                let asset = AVURLAsset(url: url, options: nil)
                preview.videoDuration = asset.duration.durationText
            } else {
                // === Photo or cleartext: existing path ===
                let thumbnail = try await createThumbnail(for: media)
                preview = PreviewModel(thumbnailMedia: thumbnail)
                if let decrypted = media as? CleartextMedia, decrypted.mediaType == .video,
                   case .url(let source) = decrypted.source {
                    let asset = AVURLAsset(url: source, options: nil)
                    preview.videoDuration = asset.duration.durationText
                }
            }

            printDebug("createPreview: Created preview for \(media.id)")
            // A preview inherits the key of the media it was made from, not the album's:
            // an album can hold media under another key, and an item whose two halves are
            // under different keys cannot be described by one fingerprint.
            try await savePreview(preview: preview,
                                  sourceMedia: media,
                                  underKey: await sourceKey(of: media))
            return preview
        } catch {
            printDebug("createPreview: Error creating preview for \(media.id)")
            throw error
        }
    }


    /// The key the media at hand is encrypted with, or nil when it is cleartext — a
    /// capture being encrypted for the first time, which is under the album key by
    /// construction.
    private func sourceKey<T: MediaDescribing>(of media: T) async -> PrivateKey? {
        guard let encrypted = media as? EncryptedMedia,
              case .url(let sourceURL) = encrypted.source else {
            return nil
        }
        return try? await resolveKey(for: sourceURL, mediaID: encrypted.id).key
    }

    private func decryptMediaToData(encrypted: EncryptedMedia, progress: (FileLoadingStatus) -> Void) async throws -> CleartextMedia {
        guard keyManager != nil else {
            throw FileAccessError.missingKeyManager
        }
        guard case .url(let sourceURL) = encrypted.source else {
            throw FileAccessError.couldNotLoadMedia
        }

        let resolution = try await resolveKey(for: sourceURL, mediaID: encrypted.id)

        let fileHandler = SecretFileHandler(keyBytes: resolution.key.keyBytes, source: encrypted)

        let decrypted: CleartextMedia = try await fileHandler.decryptInMemory()
        // A successful full decrypt is definitive proof — seed the memo even
        // when resolution came from the current-key fallback.
        discoveredKeyMemo[encrypted.id] = resolution.key.uuid
        return decrypted
    }

    /// Shared key resolution for the open paths: discovery confirms the key
    /// by authenticating the file's first block (stamp hint → xattr hint →
    /// current key → stored-key sweep). When nothing decrypts, fall back to
    /// the album key and preserve today's failure behavior exactly — the full
    /// decrypt fails through the existing `decryptError` path.
    private func resolveKey(for sourceURL: URL, mediaID: String) async throws -> (key: PrivateKey, stampMatched: Bool) {
        guard let keyManager else {
            throw FileAccessError.missingKeyManager
        }

        // Memo hit: one verification AEAD op, no candidate sweep. A stale
        // entry (e.g. the file was replaced) is dropped and falls through to
        // full discovery instead of failing the open.
        if let memoizedUUID = discoveredKeyMemo[mediaID],
           let memoizedKey = await keyManager.keyWith(uuid: memoizedUUID) {
            let (proof, stamp) = await KeyDiscovery.proveFirstBlockReadingStamp(of: sourceURL, with: memoizedKey)
            if proof == .proved {
                let stampMatched = stamp == memoizedKey.stampPrefix
                if !stampMatched && shouldStampFile(at: sourceURL) {
                    KeyStampSlot.writeStamp(memoizedKey.stampPrefix, url: sourceURL)
                }
                return (memoizedKey, stampMatched)
            }
            discoveredKeyMemo[mediaID] = nil
        }

        switch await KeyDiscovery.discoverKeyOutcome(for: sourceURL,
                                                     keyManager: keyManager,
                                                     storedKeysSnapshot: currentStoredKeys(keyManager)) {
        case .resolved(let discovered):
            printDebug("resolveKey: Discovered key '\(discovered.key.name)' for file \(mediaID), stampMatched: \(discovered.stampMatched)")
            discoveredKeyMemo[mediaID] = discovered.key.uuid
            if !discovered.stampMatched && shouldStampFile(at: sourceURL) {
                // First-block authentication is sufficient proof of the key
                // association — a mid-file corruption failure later in the
                // full decrypt doesn't invalidate it. Failures are swallowed
                // inside writeStamp; a failed stamp never fails an open.
                KeyStampSlot.writeStamp(discovered.key.stampPrefix, url: sourceURL)
            }
            return (discovered.key, discovered.stampMatched)

        case .noKnownKey(let requiredStampPrefix):
            // The media is well-formed and simply needs a key we don't have.
            // Fail loudly here instead of falling back to the current key: that
            // fallback is what turned "you're missing a key" into an
            // indistinguishable generic decryptError (ENC-76/ENC-99).
            printDebug("resolveKey: no known key decrypts \(mediaID), stamped=\(requiredStampPrefix != nil)")
            throw FileAccessError.missingKeyForMedia(requiredStampPrefix: requiredStampPrefix)

        case .unreadable:
            // Deliberately preserves the pre-ENC-99 behavior: fall back to the
            // current key and let the full decrypt fail through the existing
            // `decryptError` path. `.unreadable` also covers a not-yet-
            // downloaded iCloud placeholder, whose real error is raised further
            // up — claiming corruption here would regress that case.
            guard let currentKey = key else {
                throw FileAccessError.missingPrivateKey
            }
            printDebug("resolveKey: file \(mediaID) is unreadable as encrypted media, falling back to current key")
            return (currentKey, false)
        }
    }

    /// The iCloud Documents root (`iCloudStorageModel.rootURL` without its
    /// fatalError), resolved once. Nil when no ubiquity container exists.
    private static let ubiquityDocumentsURL: URL? = FileManager.default
        .url(forUbiquityContainerIdentifier: nil)?
        .appendingPathComponent("Documents")

    /// Local-only gate for in-file stamp writes: iCloud files still get
    /// discovery but never an in-file write — a one-byte change re-uploads
    /// the whole file (in-file stamping of iCloud files is a deferred chunk).
    /// Belt-and-braces: require local storage AND that the URL is not under
    /// the iCloud container.
    private func shouldStampFile(at url: URL) -> Bool {
        guard directoryModel is LocalStorageModel else {
            return false
        }
        if let ubiquityDocuments = Self.ubiquityDocumentsURL,
           url.standardizedFileURL.path.hasPrefix(ubiquityDocuments.standardizedFileURL.path) {
            return false
        }
        return true
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
        printDebug("decryptMediaToURL: Starting decryption for \(encrypted.id)")
        printDebug("decryptMediaToURL: keyManager exists: \(keyManager != nil)")
        
        guard keyManager != nil else {
            printDebug("decryptMediaToURL: ERROR - Missing keyManager")
            throw FileAccessError.missingKeyManager
        }

        guard case .url(let sourceURL) = encrypted.source else {
            printDebug("decryptMediaToURL: ERROR - Could not get URL from encrypted.source")
            printDebug("decryptMediaToURL: encrypted.source = \(encrypted.source)")
            throw FileAccessError.couldNotLoadMedia
        }
        
        printDebug("decryptMediaToURL: Source URL: \(sourceURL.path)")
        printDebug("decryptMediaToURL: File exists: \(FileManager.default.fileExists(atPath: sourceURL.path))")

        defer { sourceURL.stopAccessingSecurityScopedResource() }

        let targetURL = URL.tempMediaDirectory
            .appendingPathComponent(encrypted.id)
            .appendingPathExtension(encrypted.mediaType.decryptedFileExtension)
        
        printDebug("decryptMediaToURL: Target URL: \(targetURL.path)")

        if FileManager.default.fileExists(atPath: targetURL.path) {
            printDebug("decryptMediaToURL: Target already exists, returning cached")
            return CleartextMedia(source: targetURL)
        }

        let resolution = try await resolveKey(for: sourceURL, mediaID: encrypted.id)

        let fileHandler = SecretFileHandler(keyBytes: resolution.key.keyBytes, source: encrypted, targetURL: targetURL)

        fileHandler.progress
            .receive(on: DispatchQueue.main)
            .sink { percent in
                progress(.decrypting(progress: percent))
            }
            .store(in: &cancellables)
        
        printDebug("decryptMediaToURL: Calling fileHandler.decryptToURL()...")
        do {
            let decrypted = try await fileHandler.decryptToURL()
            printDebug("decryptMediaToURL: Decryption successful!")
            discoveredKeyMemo[encrypted.id] = resolution.key.uuid
            return decrypted
        } catch {
            printDebug("decryptMediaToURL: ERROR - Decryption failed: \(error)")
            printDebug("decryptMediaToURL: Error type: \(type(of: error))")
            throw error
        }
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
        } else {
            fatalError()
        }
        return thumb
    }
}



extension DiskFileAccess {

    /// `underKey` is the key the source media is encrypted with. It defaults to the
    /// album's key, which is correct only when the source is under that key — pass the
    /// resolved key for anything read off disk.
    @discardableResult public func savePreview<T: MediaDescribing>(preview: PreviewModel,
                                                                   sourceMedia: T,
                                                                   underKey: PrivateKey? = nil) async throws -> CleartextMedia {
        guard let key = underKey ?? key else {
            throw FileAccessError.missingPrivateKey
        }
        let data = try JSONEncoder().encode(preview)
        let destinationURL = directoryModel?.previewURLForMedia(sourceMedia)
        let cleartextPreview = CleartextMedia(source: data, mediaType: .preview, id: sourceMedia.id)

        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartextPreview, targetURL: destinationURL)

        let encrypted = try await fileHandler.encrypt()
        
        // Store the key UUID as an extended attribute for preview files too
        if var encryptedURL = encrypted.url {
            try? ExtendedAttributesUtil.setKeyUUID(key.uuid, for: encryptedURL)
            
            // Ensure preview files are also included in device backups
            if directoryModel?.storageType == .local {
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = false
                try? encryptedURL.setResourceValues(resourceValues)
            }
        }
        
        printDebug("Saved preview for \(sourceMedia.id)")
        return cleartextPreview
    }

    /// Deliberately has NO storage-type availability gate. Adding media to an album
    /// that already exists is permitted for every storage type, including deprecated
    /// iCloud Drive — the deprecation closes that type to new *albums*, not to writes
    /// into the ones users already have. Gating this on
    /// `DataStorageAvailabilityUtil.isStorageTypeAvailable` would silently break
    /// exactly that case; `ICloudDriveLegacyContractTests` fails if anyone does
    /// (ENC-106).
    @discardableResult public func save(media: CleartextMedia, metadata: EncryptedFileMetadata? = nil, progress: @escaping (Double) -> Void) async throws -> EncryptedMedia? {
        // Check for task cancellation at the start of save operation
        // This ensures we don't start encryption if the task is already cancelled
        try Task.checkCancellation()
        
        guard let key = key else {
            throw FileAccessError.missingPrivateKey
        }

        guard let directoryModel else {
            throw FileAccessError.missingDirectoryModel
        }
        let destinationURL = directoryModel.driveURLForMedia(media)
        
        let encrypted: EncryptedMedia
        
        if let metadata = metadata {
            let fileHandler = SecretFileHandlerV2(keyBytes: key.keyBytes, source: media, targetURL: destinationURL)
            fileHandler.progress
                .receive(on: DispatchQueue.main)
                .sink { percent in
                    progress(percent)
                }.store(in: &cancellables)

            encrypted = try await fileHandler.encryptWithMetadata(metadata)
        } else {
            let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: media, targetURL: destinationURL)
            fileHandler.progress
                .receive(on: DispatchQueue.main)
                .sink { percent in
                    progress(percent)
                }.store(in: &cancellables)

            encrypted = try await fileHandler.encrypt()
        }
        
        // Store the key UUID as an extended attribute
        if var encryptedURL = encrypted.url {
            try? ExtendedAttributesUtil.setKeyUUID(key.uuid, for: encryptedURL)

            // New local files are born stamped — they never need discovery.
            if shouldStampFile(at: encryptedURL) {
                KeyStampSlot.writeStamp(key.stampPrefix, url: encryptedURL)
            }

            // Ensure local files are included in device backups for transfer to new devices
            if directoryModel.storageType == .local {
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = false
                try? encryptedURL.setResourceValues(resourceValues)
            }
        }
        
        // Invalidate cached preview so the new one is picked up on next load
        Self.previewCache.removeObject(forKey: media.id as NSString)
        try await createPreview(for: media)
        operationBus.didCreate(encrypted)
        return encrypted
    }

    public func copy(media: EncryptedMedia) async throws {
        guard var destinationURL = directoryModel?.driveURLForMedia(media), case .url(let source) = media.source else {
            throw FileAccessError.missingDirectoryModel
        }
        try FileManager.default.copyItem(at: source, to: destinationURL)
        
        // Copy the key UUID extended attribute if it exists
        if let keyUUID = try? ExtendedAttributesUtil.getKeyUUID(for: source) {
            try? ExtendedAttributesUtil.setKeyUUID(keyUUID, for: destinationURL)
        }
        
        // Ensure copied files are included in device backups for transfer to new devices
        if directoryModel?.storageType == .local {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = false
            try? destinationURL.setResourceValues(resourceValues)
        }
        
        if let newMedia = EncryptedMedia(source: destinationURL) {
            operationBus.didCreate(newMedia)
        }
    }

    public func move(media: EncryptedMedia, progress: ((FileLoadingStatus) -> Void)? = nil) async throws {
        guard var destinationURL = directoryModel?.driveURLForMedia(media), case .url(let source) = media.source else {
            throw FileAccessError.missingDirectoryModel
        }

        // CRITICAL: Ensure iCloud files are downloaded before moving
        // iCloud files may exist only as placeholders locally. Attempting to move
        // a placeholder will either fail or only move the metadata, not the actual data.
        let downloadedMedia = try await ensureFileIsDownloadedForMove(encrypted: media, progress: progress)
        
        // Use the downloaded source URL (may be different if download was required)
        guard case .url(let downloadedSource) = downloadedMedia.source else {
            throw FileAccessError.couldNotLoadMedia
        }
        
        try FileManager.default.moveItem(at: downloadedSource, to: destinationURL)

        
        // Ensure moved files are included in device backups for transfer to new devices
        if directoryModel?.storageType == .local {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = false
            try? destinationURL.setResourceValues(resourceValues)
        }
    }
    
    /// Ensures the file is downloaded from iCloud before a move operation
    /// Similar to ensureFileIsDownloaded but with specific handling for move operations
    private func ensureFileIsDownloadedForMove(encrypted: EncryptedMedia, progress: ((FileLoadingStatus) -> Void)?) async throws -> EncryptedMedia {
        guard case .url(let sourceURL) = encrypted.source else {
            return encrypted
        }
        
        // Get comprehensive iCloud status
        let status = iCloudFileStatusUtil.getStatus(for: sourceURL)
        
        // If file is not a ubiquitous item or is already downloaded, proceed
        guard status.isUbiquitousItem else {
            return encrypted
        }
        
        switch status.downloadState {
        case .current:
            // File is fully downloaded
            return encrypted
            
        case .notDownloaded:
            // File needs to be downloaded before moving
            printDebug("File needs download from iCloud before move", encrypted.id)
            progress?(.downloading(progress: 0))
            
            // If we have an iCloud directory model, use its download method
            // Otherwise, create a temporary iCloud model to download the file
            if let iCloudDirectoryModel = directoryModel as? iCloudStorageModel {
                let downloaded = try await iCloudDirectoryModel.downloadFileFromiCloud(media: encrypted) { [weak self] prog in
                    self?.printDebug("Downloading file from iCloud for move", encrypted.id, prog)
                    progress?(.downloading(progress: prog))
                }
                return downloaded
            } else {
                // The file is in iCloud but our directoryModel is not iCloud
                // This can happen when moving from iCloud album to local album
                // We need to trigger the download and wait for it
                printDebug("File is in iCloud but directoryModel is not iCloudStorageModel, triggering download", encrypted.id)
                try iCloudFileStatusUtil.startDownload(for: sourceURL)
                
                // Wait for the download to complete with polling
                let downloaded = try await waitForICloudDownload(media: encrypted, progress: progress)
                return downloaded
            }
            
        case .downloading(let downloadProgress):
            // Download is already in progress, wait for it to complete
            printDebug("File is currently downloading from iCloud, waiting", encrypted.id, downloadProgress)
            progress?(.downloading(progress: downloadProgress))
            let downloaded = try await waitForICloudDownload(media: encrypted, progress: progress)
            return downloaded
            
        case .downloadFailed:
            // Previous download failed, try again
            printDebug("Previous iCloud download failed, retrying", encrypted.id)
            try iCloudFileStatusUtil.startDownload(for: sourceURL)
            let downloaded = try await waitForICloudDownload(media: encrypted, progress: progress)
            return downloaded
            
        case .notUbiquitous:
            // Not an iCloud file, should have been caught above
            return encrypted
        }
    }
    
    /// Waits for an iCloud file download to complete by polling
    private func waitForICloudDownload(media: EncryptedMedia, progress: ((FileLoadingStatus) -> Void)?) async throws -> EncryptedMedia {
        guard case .url(let sourceURL) = media.source else {
            return media
        }
        
        let maxWaitTime: TimeInterval = 300 // 5 minutes max wait
        let pollInterval: TimeInterval = 0.5
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            try Task.checkCancellation()
            
            let status = iCloudFileStatusUtil.getStatus(for: sourceURL)
            
            switch status.downloadState {
            case .current:
                // Download complete
                progress?(.downloading(progress: 1.0))
                return media
                
            case .downloading(let downloadProgress):
                progress?(.downloading(progress: downloadProgress / 100.0))
                
            case .downloadFailed(let error):
                throw FileAccessError.iCloudDownloadFailed(status: status)
                
            case .notDownloaded:
                // Still waiting for download to start/continue
                break
                
            case .notUbiquitous:
                // File became local somehow (e.g., was fully downloaded)
                return media
            }
            
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        
        // Timeout - throw error
        printDebug("iCloud download timed out for file", media.id)
        throw FileAccessError.iCloudDownloadTimeout
    }

    public func delete(media: [EncryptedMedia]) async throws {
        var deletedMedia: [EncryptedMedia] = []
        
        for mediaItem in media {
            // Check for cancellation before deleting each media item
            try Task.checkCancellation()
            
            guard case .url(let source) = mediaItem.source else {
                printDebug("Error deleting media: \(mediaItem)")
                throw FileAccessError.missingDirectoryModel
            }
            
            try FileManager.default.removeItem(at: source)
            if let previewURL = directoryModel?.previewURLForMedia(mediaItem) {
                try? FileManager.default.removeItem(at: previewURL)
            }
            Self.previewCache.removeObject(forKey: mediaItem.id as NSString)
            deletedMedia.append(mediaItem)
        }
        
        operationBus.didDelete(deletedMedia)
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
        Self.previewCache.removeAllObjects()
    }
    
    public func setKeyUUIDForExistingFiles() async throws {
        guard let keyManager = keyManager else {
            printDebug("setKeyUUIDForExistingFiles: No key manager available")
            throw FileAccessError.missingKeyManager
        }
        
        guard let currentKey = keyManager.currentKey else {
            printDebug("setKeyUUIDForExistingFiles: No current key available")
            throw FileAccessError.missingPrivateKey
        }
        
        printDebug("setKeyUUIDForExistingFiles: Starting UUID migration for existing files")
        
        // Get all encrypted media files across all albums
        var allEncryptedMedia: [EncryptedMedia] = await enumerateAllMedia()
        
        // Also include files from the current album if we have a directoryModel configured
        if let directoryModel = directoryModel {
            let currentAlbumMedia: [EncryptedMedia] = await enumerateMedia()
            allEncryptedMedia.append(contentsOf: currentAlbumMedia)
        }
        
        // Remove duplicates based on file URL
        var uniqueMedia: [EncryptedMedia] = []
        var seenURLs: Set<URL> = []
        
        for media in allEncryptedMedia {
            if case .url(let fileURL) = media.source, !seenURLs.contains(fileURL) {
                seenURLs.insert(fileURL)
                uniqueMedia.append(media)
            }
        }
        
        var processedCount = 0
        var updatedCount = 0
        print("encrypted media", uniqueMedia.map({$0.id}))

        for media in uniqueMedia {
            // Check for cancellation periodically during UUID migration
            try Task.checkCancellation()
            
            guard case .url(let fileURL) = media.source else {
                continue
            }
            
            processedCount += 1
            
            do {
                // Check if UUID is already set
                let existingUUID = try? ExtendedAttributesUtil.getKeyUUID(for: fileURL)
                
                if existingUUID == nil {
                    // No UUID set, set it to the current key's UUID
                    try ExtendedAttributesUtil.setKeyUUID(currentKey.uuid, for: fileURL)
                    updatedCount += 1
                    printDebug("setKeyUUIDForExistingFiles: Set UUID for file \(media.id)")
                } else {
                    printDebug("setKeyUUIDForExistingFiles: File \(media.id) already has UUID, skipping")
                }
            } catch {
                printDebug("setKeyUUIDForExistingFiles: Failed to process file \(media.id): \(error)")
            }
        }
        
        // Also process preview files across all storage types
        var allPreviewFiles = enumerateAllPreviewFiles()
        
        // Include preview files from current album if we have a directoryModel
        if let directoryModel = directoryModel {
            let currentAlbumPreviewFiles = directoryModel.enumeratePreviewFiles()
            allPreviewFiles.append(contentsOf: currentAlbumPreviewFiles)
        }
        
        // Remove duplicate preview files
        let uniquePreviewFiles = Array(Set(allPreviewFiles))
        
        for previewURL in uniquePreviewFiles {
            // Check for cancellation periodically during preview file UUID migration
            try Task.checkCancellation()
            
            processedCount += 1
            
            do {
                let existingUUID = try? ExtendedAttributesUtil.getKeyUUID(for: previewURL)
                
                if existingUUID == nil {
                    try ExtendedAttributesUtil.setKeyUUID(currentKey.uuid, for: previewURL)
                    updatedCount += 1
                    printDebug("setKeyUUIDForExistingFiles: Set UUID for preview file \(previewURL.lastPathComponent)")
                }
            } catch {
                printDebug("setKeyUUIDForExistingFiles: Failed to process preview file \(previewURL.lastPathComponent): \(error)")
            }
        }
        
        printDebug("setKeyUUIDForExistingFiles: Completed. Processed \(processedCount) files, updated \(updatedCount) files")
    }
    public static func deleteThumbnailDirectory() throws {
        try LocalStorageModel.deletePreviewDirectory()
        try iCloudStorageModel.deletePreviewDirectory()
    }

    var operationBus: FileOperationBus {
        FileOperationBus.shared
    }


}

