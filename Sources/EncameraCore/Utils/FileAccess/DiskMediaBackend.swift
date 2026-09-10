//
//  DiskMediaBackend.swift
//  EncameraCore
//
//  The local/iCloud-Drive `MediaBackend`. Wraps a single `DiskFileAccess` (the
//  low-level per-component engine, unchanged) and contains exactly the grouping /
//  per-item logic that used to live inline in the `else` branches of
//  `InteractableMediaFileAccess`. The facade now picks one backend at
//  `configure(...)` time and talks to it through `MediaBackend`.
//

import Foundation
import UIKit

public actor DiskMediaBackend: MediaBackend {

    private let fileAccess: DiskFileAccess
    private var directoryModel: DataStorageModel?
    /// The album's media index. This backend is its sole writer — it patches the
    /// store incrementally on every mutation and rebuilds it in `reconcile`. The
    /// store owns the warm cache and the persist/rollback envelope; this backend
    /// only produces inputs and reads through `store.current()`.
    private var indexStore: MediaIndexStore?
    private var albumID: String?

    public init() {
        self.fileAccess = DiskFileAccess()
    }

    public func configure(for album: Album, albumManager: AlbumManaging) async {
        await fileAccess.configure(for: album, albumManager: albumManager)
        self.directoryModel = albumManager.storageModel(for: album)
        // Only reset the index when switching albums — re-configuring for the same
        // album (e.g. a gallery refresh) keeps the store's warm in-memory cache.
        if albumID != album.id {
            self.albumID = album.id
            self.indexStore = MediaIndexStore(album: album)
        }
    }

    // MARK: - Enumeration

    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T: MediaDescribing {
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

    public func enumerateMediaWithMetadata(
        sortBy sortOption: MediaSortOption = .dateEncrypted(ascending: false),
        filterBy filterOptions: MediaFilterOptions = .all
    ) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] {
        // Get raw encrypted media with metadata from DiskFileAccess
        let rawMediaWithMetadata = await fileAccess.enumerateEncryptedMediaWithMetadata(
            sortBy: sortOption,
            filterBy: filterOptions
        )

        // Group by media ID (for Live Photos which have photo + video components)
        // We need to preserve the order while grouping
        var mediaMap: [String: (interactable: InteractableMedia<EncryptedMedia>, metadata: EncryptedFileMetadata?, dateTaken: Date?, dateEncrypted: Date?, subtype: MediaFilterOptions)] = [:]
        var orderedIds: [String] = []

        for item in rawMediaWithMetadata {
            let mediaId = item.media.id

            if var existing = mediaMap[mediaId] {
                // Add to existing group (e.g., video component of Live Photo)
                existing.interactable.appendToUnderlyingMedia(media: item.media)
                mediaMap[mediaId] = existing
            } else {
                // Create new group
                do {
                    let interactable = try InteractableMedia(underlyingMedia: [item.media])
                    mediaMap[mediaId] = (
                        interactable: interactable,
                        metadata: item.metadata,
                        dateTaken: item.dateTaken,
                        dateEncrypted: item.dateEncrypted,
                        subtype: item.mediaSubtype
                    )
                    orderedIds.append(mediaId)
                } catch {
                    debugPrint("Could not create interactable media: \(error)")
                }
            }
        }

        // Build result array preserving order
        var results: [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] = []

        for mediaId in orderedIds {
            guard let group = mediaMap[mediaId] else { continue }

            // For Live Photos, treat as still images for filtering purposes
            var subtype = group.subtype
            if group.interactable.mediaType == .livePhoto {
                subtype = .stillImage
            }

            let wrapper = MediaWithMetadata(
                media: group.interactable,
                metadata: group.metadata,
                dateTaken: group.dateTaken,
                dateEncrypted: group.dateEncrypted,
                mediaSubtype: subtype
            )
            results.append(wrapper)
        }

        return results
    }

    public func totalStoredMediaCount() async -> Int {
        await fileAccess.totalStoredMediaCount()
    }

    // MARK: - Read

    public func loadMediaPreview<T>(for media: InteractableMedia<T>) async throws -> PreviewModel where T: MediaDescribing {
        var preview = try await fileAccess.loadMediaPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    public func loadMediaToURLs(
        media: InteractableMedia<EncryptedMedia>,
        progress: @escaping (FileLoadingStatus) -> Void
    ) async throws -> [URL] {
        var urls = [URL]()
        for mediaItem in media.underlyingMedia {
            // Check for cancellation before loading each media item
            try Task.checkCancellation()

            let loaded = try await fileAccess.loadMediaToURL(media: mediaItem, progress: progress)
            guard let url = loaded.url else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    public func loadMedia<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T: MediaDescribing {
        var decrypted: [CleartextMedia] = []
        for mediaItem in media.underlyingMedia {
            // Check for cancellation before decrypting each media item
            try Task.checkCancellation()

            if mediaItem.mediaType == .photo {
                let cleartextMedia = try await fileAccess.loadMediaInMemory(media: mediaItem, progress: progress)
                decrypted.append(cleartextMedia)
            } else if mediaItem.mediaType == .video {
                let cleartextMedia = try await fileAccess.loadMediaToURL(media: mediaItem, progress: progress)
                decrypted.append(cleartextMedia)
            }
        }
        progress(.loaded)
        return try InteractableMedia(underlyingMedia: decrypted)
    }

    /// Backend-level cover-thumbnail resolution. `DiskFileAccess.loadLeadingThumbnail`
    /// already reads the album's cover id itself and resolves it (or the default
    /// first item) through the disk preview pipeline, so we delegate to it. The
    /// `coverImageId` parameter is unused on disk (the cloud backend uses it).
    public func loadLeadingThumbnail(coverImageId: String?) async throws -> UIImage? {
        try await fileAccess.loadLeadingThumbnail()
    }

    // MARK: - Write

    public func save(media: InteractableMedia<CleartextMedia>, metadata: EncryptedFileMetadata?, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        var encrypted: [EncryptedMedia] = []
        for mediaItem in media.underlyingMedia {
            // Check for cancellation before processing each media item
            // This ensures cancellation propagates through the actor boundary
            try Task.checkCancellation()
            if let encryptedMedia = try await fileAccess.save(media: mediaItem, metadata: metadata, progress: progress) {
                encrypted.append(encryptedMedia)
            }
        }

        // Fold the new item into the index immediately — no wait for a reconcile.
        await upsertIntoIndex(encrypted)
        return try InteractableMedia(underlyingMedia: encrypted)
    }

    /// Folds freshly-written components into the index by id (Live Photo
    /// components collapse into one entry), reading each file's metadata so the
    /// entry matches what a reconcile would produce. The store owns the actual
    /// upsert/persist/cache; this only derives the inputs. The incremental
    /// counterpart to a reconcile scan for adds.
    private func upsertIntoIndex(_ media: [EncryptedMedia]) async {
        guard !media.isEmpty else { return }
        let withMetadata = await fileAccess.encryptedMediaWithMetadata(for: media)
        let entries = Self.makeEntries(fromFileLevelMetadata: withMetadata)
        guard !entries.isEmpty else { return }
        do {
            try await indexStore?.upsert(entries)
        } catch {
            debugPrint("[DiskMediaBackend] failed to persist index after add: \(error)")
        }
    }

    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        var preview = try await fileAccess.createPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        for mediaItem in media.underlyingMedia {
            // Check for cancellation before copying each media item
            try Task.checkCancellation()
            try await fileAccess.copy(media: mediaItem)
        }
        // Copy mints a fresh id that `fileAccess.copy` does not return, so the new
        // file is folded in by the next reconcile (the gallery's create-bus event
        // triggers one) rather than an incremental upsert here.
    }

    public func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)? = nil) async throws {
        for mediaItem in media.underlyingMedia {
            // Check for cancellation before moving each media item
            try Task.checkCancellation()
            try await fileAccess.move(media: mediaItem, progress: progress)
        }
        // This backend is the move TARGET — the files now live under our own
        // `sourceURL` scheme, so fold them into the target index. The SOURCE
        // album drops them on its own next reconcile (the move UI triggers one);
        // writing another album's index from here would couple the backends.
        var moved: [EncryptedMedia] = []
        for item in media.underlyingMedia {
            let url = await sourceURL(id: item.id, type: item.mediaType)
            moved.append(EncryptedMedia(source: .url(url), mediaType: item.mediaType, id: item.id))
        }
        await upsertIntoIndex(moved)
    }

    public func delete(media: [InteractableMedia<EncryptedMedia>]) async throws {
        // Delete by id off a fresh directory listing rather than trusting the
        // components the caller carries: those come from the index, and an index
        // that lost a Live Photo's video component would leave the `.encvideo`
        // behind for the next reconcile to resurface as a standalone 1–2 second
        // video. Whatever shares the id goes with it.
        let allMediaItems = Self.componentsOnDisk(
            forIDs: Set(media.map { $0.id }),
            urlsByID: currentMediaURLsByID()
        )
        try await fileAccess.delete(media: allMediaItems)
        // Disk delete removes every component of a logical item, so drop whole ids.
        do {
            try await indexStore?.remove(ids: Set(media.map { $0.id }))
        } catch {
            debugPrint("[DiskMediaBackend] failed to persist index after delete: \(error)")
        }
    }

    public func deleteAllMedia() async throws {
        try await fileAccess.deleteAllMedia()
        do {
            try await indexStore?.replace(with: [])
        } catch {
            debugPrint("[DiskMediaBackend] failed to clear index after deleteAllMedia: \(error)")
        }
    }

    public func setKeyUUIDForExistingFiles() async throws {
        try await fileAccess.setKeyUUIDForExistingFiles()
    }

    // MARK: - Source URL

    public func sourceURL(id: String, type: MediaType) async -> URL {
        guard let directoryModel else {
            // No configured album yet — fall back to a best-effort path so callers
            // never crash; an unconfigured backend should not be materializing.
            return URL(fileURLWithPath: "/dev/null")
        }
        return directoryModel.driveURLForMedia(withID: id, type: type)
    }

    // MARK: - Storage details

    /// `MediaBackend.storageDetails`. Every component is a real file in the album
    /// directory, so the format is sniffed straight off disk and the size is the
    /// file's own.
    ///
    /// The remote/local split only means something for `.icloud`, where the album
    /// directory sits in the ubiquity container and a file may be a placeholder
    /// rather than bytes. There, the item's logical size is what iCloud Drive
    /// holds and `localBytes` is populated only once the file is materialized.
    /// A `.local` album has no remote side at all.
    public func storageDetails(for media: InteractableMedia<EncryptedMedia>) async -> MediaStorageDetails? {
        guard let directoryModel else { return nil }
        let storageType = directoryModel.storageType
        var components: [MediaStorageDetails.Component] = []
        for item in media.underlyingMedia {
            let url = await sourceURL(id: item.id, type: item.mediaType)
            let isDownloaded = storageType != .icloud || !iCloudFileStatusUtil.needsDownload(url: url)
            let logicalBytes = Self.logicalFileSize(at: url)
            let format = isDownloaded ? EncryptedFormatVersion.sniff(fileURL: url) : nil
            components.append(
                MediaStorageDetails.Component(
                    mediaType: item.mediaType,
                    // iCloud Drive stores exactly the file we would hold locally, so
                    // one size describes both sides.
                    remoteBytes: storageType == .icloud ? logicalBytes : nil,
                    localBytes: isDownloaded ? logicalBytes : nil,
                    format: format,
                    chunkCount: format == .v3 ? Self.chunkCount(ofSeekableFileAt: url) : nil
                )
            )
        }
        return MediaStorageDetails(storageType: storageType, components: components)
    }

    /// `MediaBackend.evictLocalCopy`. Only an iCloud Drive album has a copy that
    /// is safe to drop — `evictUbiquitousItem` leaves the item in iCloud and
    /// replaces the local bytes with a placeholder. In a `.local` album the bytes
    /// on disk are the media, so the request is refused.
    public func evictLocalCopy(for media: InteractableMedia<EncryptedMedia>) async throws {
        guard let directoryModel, directoryModel.storageType == .icloud else {
            throw FileAccessError.localCopyNotEvictable
        }
        for item in media.underlyingMedia {
            let url = await sourceURL(id: item.id, type: item.mediaType)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.evictUbiquitousItem(at: url)
        }
    }

    /// The item's size in bytes regardless of whether its bytes are present.
    /// `totalFileSize` is what an undownloaded ubiquitous placeholder reports; a
    /// materialized file has no `totalFileSize` and answers with `fileSize`.
    private static func logicalFileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey]),
              let bytes = values.totalFileSize ?? values.fileSize else {
            return nil
        }
        return Int64(bytes)
    }

    /// Chunk count read out of an ENC3 file's header. `nil` when the header
    /// cannot be read — a truncated file names no chunk count rather than zero.
    private static func chunkCount(ofSeekableFileAt url: URL) -> Int? {
        (try? SeekableEncryptedHeader.read(fromFileAt: url))?.header.chunkCount
    }

    // MARK: - Media index

    /// Serves the album's index through the store's read-through cache. Returns
    /// `nil` if no index has been built yet — building is the job of `reconcile()`.
    public func mediaIndex() async -> MediaIndex? {
        await indexStore?.current()
    }

    // MARK: - Reconcile (disk scan)

    /// Brings the index in sync with the album's files. Lists the directory by
    /// name only (no `stat`, no decryption), then incrementally drops entries for
    /// removed files and reads metadata for *only* the newly-added/modified files —
    /// so this stays cheap even on a large album. Returns whether the index
    /// changed. Honors cancellation: a cancelled scan bails before writing.
    @discardableResult
    public func reconcile(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)? = nil
    ) async -> Bool {
        guard let indexStore else { return false }

        // The scan below suspends this actor (directory listing → index reload →
        // metadata reads), so an incremental save/delete/move can interleave and
        // patch the index mid-scan. Capture the store's mutation generation before
        // snapshotting anything and make the final write conditional on it: if the
        // index moved on, re-diff against the updated state instead of clobbering
        // the interleaved write with our stale snapshot. Interleaved mutations are
        // user-driven and rare, so a couple of retries always suffice.
        for _ in 0..<3 {
            let generation = await indexStore.currentGeneration()

            let diskURLsByID = currentMediaURLsByID()
            let diskIDs = Set(diskURLsByID.keys)
            // Diff against the authoritative on-disk index — a reconcile must see
            // external writes (e.g. a migration rebuild), not a possibly-stale cache.
            let existingEntries = (await indexStore.reloadFromDisk())?.entries ?? []
            let indexIDs = Set(existingEntries.map { $0.id })

            let removedIDs = indexIDs.subtracting(diskIDs)
            let addedIDs = diskIDs.subtracting(indexIDs)

            let unchangedIDs = indexIDs.intersection(diskIDs)

            // Detect in-place modifications for entries whose IDs still match, relative
            // to when the index file was last written.
            let modifiedIDs: Set<String>
            if let referenceDate = indexStore.fileModificationDate() {
                modifiedIDs = Self.idsModifiedSince(referenceDate, among: unchangedIDs, urlsByID: diskURLsByID)
            } else {
                modifiedIDs = []
            }

            // Detect entries whose recorded components no longer describe the files
            // on disk. The id-level diff above is blind to this — the id is in both
            // sets — and the mtime check misses it whenever the index file has been
            // rewritten since the component landed, which a busy album does on every
            // save. Without this, a Live Photo that was only half-recorded (a
            // component that threw after writing its file, or a gallery refresh that
            // indexed the item between its photo and video writes) is stuck as a
            // still photo forever, with an invisible `.encvideo` beside it.
            let mismatchedIDs = Self.idsWithComponentMismatch(
                among: unchangedIDs,
                urlsByID: diskURLsByID,
                entries: existingEntries
            )

            let staleIDs = modifiedIDs.union(mismatchedIDs)

            guard !removedIDs.isEmpty || !addedIDs.isEmpty || !staleIDs.isEmpty else {
                return false
            }

            // A cancelled reconcile must not write a partial index.
            if Task.isCancelled { return false }

            var entries = existingEntries.filter {
                !removedIDs.contains($0.id) && !staleIDs.contains($0.id)
            }

            let idsToRead = addedIDs.union(staleIDs)
            if !idsToRead.isEmpty {
                let mediaToRead: [EncryptedMedia] = idsToRead.flatMap { id in
                    (diskURLsByID[id] ?? []).compactMap {
                        EncryptedMedia(source: .url($0), generateID: false)
                    }
                }
                let withMetadata = await fileAccess.encryptedMediaWithMetadata(
                    for: mediaToRead,
                    onProgress: onProgress
                )
                entries.append(contentsOf: Self.makeEntries(fromFileLevelMetadata: withMetadata))
            }

            // The metadata read above can be long; bail without writing if cancelled.
            if Task.isCancelled { return false }

            do {
                guard try await indexStore.replace(with: entries, ifGenerationIs: generation) else {
                    continue
                }
            } catch {
                debugPrint("[DiskMediaBackend] failed to persist reconciled index: \(error)")
                return false
            }
            return true
        }
        return false
    }

    // MARK: - Reconcile helpers

    /// Returns IDs whose files on disk have a modification date newer than the
    /// given reference date — a lightweight way to detect in-place edits.
    static func idsModifiedSince(
        _ referenceDate: Date,
        among ids: Set<String>,
        urlsByID: [String: [URL]]
    ) -> Set<String> {
        var modified = Set<String>()
        for id in ids {
            guard let urls = urlsByID[id] else { continue }
            for url in urls {
                if let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate > referenceDate {
                    modified.insert(id)
                    break
                }
            }
        }
        return modified
    }

    /// Every component file currently on disk for the given ids, as deletable
    /// `EncryptedMedia`. Sourcing the delete list from disk rather than from the
    /// index means an unrecorded component is still removed, and a component the
    /// index claims but disk has already lost is skipped instead of throwing
    /// mid-loop and stranding the components after it.
    static func componentsOnDisk(
        forIDs ids: Set<String>,
        urlsByID: [String: [URL]]
    ) -> [EncryptedMedia] {
        ids.sorted().flatMap { id in
            (urlsByID[id] ?? []).compactMap { EncryptedMedia(source: .url($0), generateID: false) }
        }
    }

    /// IDs whose components on disk disagree with what the index records for them —
    /// an entry missing a component whose file is present, or claiming one whose
    /// file is gone. Re-reading these is what repairs a half-recorded Live Photo.
    ///
    /// Component classification here goes through the same
    /// `EncryptedMedia(source:generateID:)` derivation that `reconcile` feeds into
    /// `makeEntries`, so a re-read always produces the flags this check expects —
    /// an id can never be reported mismatched twice in a row.
    static func idsWithComponentMismatch(
        among ids: Set<String>,
        urlsByID: [String: [URL]],
        entries: [MediaIndexEntry]
    ) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var entriesByID: [String: MediaIndexEntry] = [:]
        for entry in entries where ids.contains(entry.id) {
            entriesByID[entry.id] = entry
        }

        var mismatched = Set<String>()
        for id in ids {
            guard let entry = entriesByID[id] else { continue }
            var hasPhoto = false
            var hasVideo = false
            for url in urlsByID[id] ?? [] {
                switch EncryptedMedia(source: .url(url), generateID: false)?.mediaType {
                case .photo: hasPhoto = true
                case .video: hasVideo = true
                default: break
                }
            }
            if hasPhoto != entry.hasPhotoComponent || hasVideo != entry.hasVideoComponent {
                mismatched.insert(id)
            }
        }
        return mismatched
    }

    /// Media file URLs currently on disk, grouped by media id, from a cheap
    /// directory listing. The modification date is prefetched so the reconcile's
    /// in-place-edit check reads it from cache rather than issuing a fresh
    /// `stat` per file.
    private func currentMediaURLsByID() -> [String: [URL]] {
        guard let directoryModel else { return [:] }
        let urls = directoryModel.enumeratorForStorageDirectory(
            resourceKeys: [.contentModificationDateKey],
            fileExtensionFilter: [
                MediaType.photo.encryptedFileExtension,
                MediaType.video.encryptedFileExtension
            ]
        )
        var grouped: [String: [URL]] = [:]
        for url in urls {
            guard let id = EncryptedMedia(source: .url(url), generateID: false)?.id else { continue }
            grouped[id, default: []].append(url)
        }
        return grouped
    }

    /// Maps file-level metadata to one `MediaIndexEntry` per component and folds
    /// them into one entry per id through the shared `upsert` algebra — a Live
    /// Photo's photo and video components (sharing an id) collapse into a single
    /// entry with both flags set. Insertion order follows first appearance.
    private static func makeEntries(
        fromFileLevelMetadata items: [MediaWithMetadata<EncryptedMedia>]
    ) -> [MediaIndexEntry] {
        var entries: [MediaIndexEntry] = []
        for item in items {
            entries.upsert(entry(forFileLevelMetadata: item))
        }
        return entries
    }

    /// One single-component `MediaIndexEntry` for a single encrypted file. Live
    /// Photo components share an id and are merged by `upsert` in `makeEntries`.
    /// Source-specific (file metadata -> entry), so it stays here rather than on
    /// the shared algebra — but it feeds the shared `upsert`. `internal` for the
    /// disk/cloud index-equivalence test.
    static func entry(
        forFileLevelMetadata item: MediaWithMetadata<EncryptedMedia>
    ) -> MediaIndexEntry {
        MediaIndexEntry(
            id: item.media.id,
            hasPhotoComponent: item.media.mediaType == .photo,
            hasVideoComponent: item.media.mediaType == .video,
            dateEncrypted: item.dateEncrypted,
            dateTaken: item.dateTaken,
            subtypeRawValue: item.mediaSubtype.rawValue
        )
    }

    // MARK: - Test hooks

    /// Test-only: wire an explicit `MediaIndexStore` (with its own cache) so a test
    /// can exercise the backend against a known index file without a full `Album`
    /// graph. Cache/reload/rollback behavior now lives on the store and is tested
    /// directly there (`MediaIndexStoreStateTests`).
    internal func _testSetIndexStore(_ store: MediaIndexStore) {
        self.indexStore = store
    }
}
