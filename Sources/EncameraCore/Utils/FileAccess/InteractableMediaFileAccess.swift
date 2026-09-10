//  Created by Alexander Freas on 17.07.24.
//

import Foundation
import UIKit

public actor InteractableMediaFileAccess: FileAccess {
    public init() {
    }

    /// The single per-album backend, chosen in `configure(for:)`. A `.cloudKit`
    /// album gets a `CloudKitFileAccess`; everything else gets a `DiskMediaBackend`.
    /// The facade talks to it only through `MediaBackend` — no `if cloudKit { … }`
    /// branching across the I/O methods.
    private var backend: (any MediaBackend)?
    private var album: Album?
    private var albumManager: AlbumManaging?

    // MARK: - Media Index state

    /// Kept for the disk-only `undownloadedMediaCount` scan and the `sourceURL`
    /// fallback; the media index itself is owned and cached by the backend.
    private var directoryModel: DataStorageModel?

    public init(for album: Album, albumManager: AlbumManaging) async {
        await configure(for: album, albumManager: albumManager)
    }

    public func configure(for album: Album, albumManager: AlbumManaging) async {
        let albumChanged = self.album?.id != album.id
        self.album = album
        self.albumManager = albumManager
        self.directoryModel = albumManager.storageModel(for: album)

        // The single backend decision point. Pick exactly one backend for the
        // album's storage option. The feature flag gates whether NEW cloudKit
        // albums can be *created* (availability), not whether an existing one uses
        // CloudKit — otherwise toggling the flag off would strand a cloudKit album.
        if albumChanged || backend == nil {
            if album.storageOption == .cloudKit {
                // `start()` is CloudKit-concrete (intentionally not in the
                // protocol); construct with the concrete type so we can warm it up
                // without a type-check, then store it as `any MediaBackend`.
                let cloud = await CloudKitFileAccess(album: album, albumManager: albumManager)
                self.backend = cloud
                Task { await cloud.start() }
            } else {
                let disk = DiskMediaBackend()
                await disk.configure(for: album, albumManager: albumManager)
                self.backend = disk
            }
        } else {
            // Same album, refreshed: re-point the existing backend at the album's
            // (possibly updated) directory model.
            await backend?.configure(for: album, albumManager: albumManager)
        }
    }

    /// Throwing accessor for the configured backend. In practice `configure(...)`
    /// always runs before any I/O; this guards the parameterless-`init()` edge.
    private func requireBackend() throws -> any MediaBackend {
        guard let backend else { throw FileAccessError.missingDirectoryModel }
        return backend
    }

    // MARK: - Backend delegation (the `MediaBackend` surface)

    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T: MediaDescribing {
        await backend?.enumerateMedia() ?? []
    }

    public func enumerateMediaWithMetadata(
        sortBy sortOption: MediaSortOption = .dateEncrypted(ascending: false),
        filterBy filterOptions: MediaFilterOptions = .all
    ) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] {
        await backend?.enumerateMediaWithMetadata(sortBy: sortOption, filterBy: filterOptions) ?? []
    }

    /// Facade-level, permission-gated cover resolution. The backend-level
    /// `loadLeadingThumbnail(coverImageId:)` does the actual fetch; this method
    /// owns the purchase-permission loop, which is not a backend concern.
    public func loadLeadingThumbnail(purchasedPermissions: (any PurchasedPermissionManaging)?) async throws -> UIImage? {
        guard let album, let albumManager else { return nil }
        guard let purchasedPermissions else { return nil }
        if albumManager.isAlbumCoverImageDisabled(album: album) {
            return nil
        }

        if let coverImageId = albumManager.getAlbumCoverImageId(album: album) {
            // Resolve the explicit cover through the backend (disk reads its local
            // preview; cloud fetches the eager thumbnail). Previously this always
            // hit disk — wrong for cloud albums.
            return try await requireBackend().loadLeadingThumbnail(coverImageId: coverImageId)
        }

        if album.storageOption == .cloudKit {
            let sidecar = AlbumCoverSidecar(album: album)
            if let syncedCoverID = await sidecar.coverMediaID() {
                return try await requireBackend().loadLeadingThumbnail(coverImageId: syncedCoverID)
            }
        }

        // No explicit cover: pick the most-recent photo the user is allowed to see.
        let media: [InteractableMedia<EncryptedMedia>] = await enumerateMedia()
        guard !media.isEmpty else {
            return nil
        }

        let totalCount = media.count
        for index in 0..<totalCount {
            // Stop promptly if the load was cancelled (the common case on a fast
            // gallery scroll) instead of grinding through every candidate.
            try Task.checkCancellation()
            let accessCount = Double(totalCount - index)
            if purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: accessCount)) {
                let targetMedia = media[index]
                do {
                    // Route through `loadMediaPreview` so CloudKit albums fetch the
                    // eager thumbnail instead of reading a (possibly absent) local file.
                    let cleartextPreview = try await loadMediaPreview(for: targetMedia)
                    guard let previewData = cleartextPreview.thumbnailMedia.data,
                          let thumbnail = UIImage(data: previewData) else {
                        continue // Try next photo if thumbnail generation fails
                    }
                    return thumbnail
                } catch {
                    // Never swallow cancellation — let the torn-down load stop.
                    if error is CancellationError { throw error }
                    continue // Try next photo if preview loading fails
                }
            }
        }

        // If we can't access any photos, return nil
        return nil
    }

    /// Backend-level cover resolution (also part of `FileReader`). Delegates
    /// straight through to the configured backend.
    public func loadLeadingThumbnail(coverImageId: String?) async throws -> UIImage? {
        try await requireBackend().loadLeadingThumbnail(coverImageId: coverImageId)
    }

    public func loadMediaPreview<T>(for media: InteractableMedia<T>) async throws -> PreviewModel where T: MediaDescribing {
        try await requireBackend().loadMediaPreview(for: media)
    }

    public func loadMediaToURLs(
        media: InteractableMedia<EncryptedMedia>,
        progress: @escaping (FileLoadingStatus) -> Void) async throws -> [URL] {
        try await requireBackend().loadMediaToURLs(media: media, progress: progress)
    }

    public func loadMedia<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T: MediaDescribing {
        try await requireBackend().loadMedia(media: media, progress: progress)
    }

    public func storageDetails(for media: InteractableMedia<EncryptedMedia>) async -> MediaStorageDetails? {
        await backend?.storageDetails(for: media) ?? nil
    }

    public func evictLocalCopy(for media: InteractableMedia<EncryptedMedia>) async throws {
        try await requireBackend().evictLocalCopy(for: media)
    }

    public func streamingPlayback(for media: InteractableMedia<EncryptedMedia>) async throws -> StreamingPlayback? {
        try await requireBackend().streamingPlayback(for: media)
    }

    public func save(media: InteractableMedia<CleartextMedia>, metadata: EncryptedFileMetadata?, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        try await requireBackend().save(media: media, metadata: metadata, progress: progress)
    }

    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        try await requireBackend().createPreview(for: media)
    }

    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        // Cloud throws `operationNotSupported`; disk performs the copy. The branch
        // lives in the backend now, not here.
        try await requireBackend().copy(media: media)
    }

    public func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)? = nil) async throws {
        try await requireBackend().move(media: media, progress: progress)
    }

    public func delete(media: [InteractableMedia<EncryptedMedia>]) async throws {
        // The backend deletes the files and patches its own index; the facade just
        // forwards the call.
        try await requireBackend().delete(media: media)
    }

    public func deleteAllMedia() async throws {
        // Erase-all must work on an unconfigured facade: the forgot-password
        // flow constructs `InteractableMediaFileAccess()` with no album and
        // expects an all-storage sweep (as `DiskFileAccess.deleteAllMedia`
        // always provided). Only delegate when a backend exists so its index
        // cleanup runs too.
        if let backend {
            try await backend.deleteAllMedia()
        } else {
            try await DiskFileAccess().deleteAllMedia()
        }
    }

    public func setKeyUUIDForExistingFiles() async throws {
        // Routes to the backend: disk backfills key-UUID xattrs; cloud is a no-op
        // (CloudKit blobs carry their key association via the record/metadata).
        try await requireBackend().setKeyUUIDForExistingFiles()
    }

    public func totalStoredMediaCount() async -> Int {
        await backend?.totalStoredMediaCount() ?? 0
    }

    public func sourceURL(id: String, type: MediaType) async -> URL {
        if let backend {
            return await backend.sourceURL(id: id, type: type)
        }
        return directoryModel?.driveURLForMedia(withID: id, type: type) ?? URL(fileURLWithPath: "/dev/null")
    }

    /// `MediaBackend.mediaIndex` on the facade reads straight through to the
    /// configured backend, which owns the index.
    public func mediaIndex() async -> MediaIndex? {
        await backend?.mediaIndex()
    }

    /// `MediaBackend.reconcile` on the facade is the same operation as
    /// `reconcileIndex` — forward to the backend, which syncs its store and
    /// refreshes its own cache.
    @discardableResult
    public func reconcile(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)? = nil
    ) async -> Bool {
        await reconcileIndex(onProgress: onProgress)
    }

    // MARK: - Media Index

    /// Rebuilds the index from scratch by reconciling against an empty index —
    /// every file on disk is treated as new and has its metadata read. Used by
    /// the startup migration.
    /// - Parameter onProgress: Optional `(filesRead, totalFiles)` callback for
    ///   reporting how far the rebuild has progressed.
    @discardableResult
    public func rebuildIndex(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)? = nil
    ) async -> MediaIndex {
        // Only called by the startup migration for albums that have no index yet,
        // so the backend's reconcile already starts from an empty index and treats
        // every file as new — no explicit reset needed. Uniform across backends.
        await reconcileIndex(onProgress: onProgress)
        return await backend?.mediaIndex() ?? MediaIndex(entries: [])
    }

    /// Brings the index in sync with the album's backing store. The per-backend
    /// mechanics (disk scan vs. CloudKit delta sync) and the cache refresh both
    /// live in `MediaBackend.reconcile` now — the facade just forwards.
    /// - Parameter onProgress: Optional `(filesRead, totalFiles)` callback that
    ///   fires while a disk backend reads metadata for added/modified files
    ///   (ignored by the CloudKit backend).
    @discardableResult
    public func reconcileIndex(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)? = nil
    ) async -> Bool {
        await backend?.reconcile(onProgress: onProgress) ?? false
    }

    /// Produces a page of media from the index. Pure in-memory work: filter and
    /// sort the backend's index entries, then materialize the slice into
    /// `InteractableMedia` without touching the filesystem or decrypting anything.
    /// Returns an empty page if no index has been built yet — `reconcileIndex()`
    /// will build one.
    public func mediaPage(
        sortBy sortOption: MediaSortOption,
        filterBy filterOptions: MediaFilterOptions,
        offset: Int,
        pageSize: Int
    ) async -> MediaPageResult {
        guard let index = await backend?.mediaIndex() else {
            return MediaPageResult(media: [], totalCount: 0, nextOffset: 0)
        }
        /* begin fault injection hook */
        // UI-test fault injection: widens the per-page window so a test can
        // interleave a UI action between page loads. Inert in production.
        let delayMs = MediaIndexTestHooks.pageLoadDelayMs
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
        /* end fault injection hook */
        let sorted = index.sortedFilteredEntries(sortBy: sortOption, filterBy: filterOptions)
        let start = max(0, min(offset, sorted.count))
        let limit = max(0, pageSize)
        var media: [InteractableMedia<EncryptedMedia>] = []
        var cursor = start
        while media.count < limit, cursor < sorted.count {
            if let item = await materialize(sorted[cursor]) {
                media.append(item)
            }
            cursor += 1
        }
        return MediaPageResult(media: media, totalCount: sorted.count, nextOffset: cursor)
    }

    // MARK: - Media Index helpers

    /// Builds an `InteractableMedia` for an index entry by reconstructing its
    /// file URLs — no filesystem read, no decryption. The per-backend URL scheme
    /// (`id.ext` for disk, `id#type` blob-cache path for CloudKit) comes from the
    /// backend's `sourceURL`, so the facade does not type-check the backend.
    private func materialize(_ entry: MediaIndexEntry) async -> InteractableMedia<EncryptedMedia>? {
        /* begin fault injection hook */
        let stride = MediaIndexTestHooks.failMaterializeStride
        if stride > 0, abs(entry.id.hashValue) % stride == 0 {
            return nil
        }
        /* end fault injection hook */
        guard let backend else { return nil }
        var underlying: [EncryptedMedia] = []
        if entry.hasPhotoComponent {
            let url = await backend.sourceURL(id: entry.id, type: .photo)
            underlying.append(EncryptedMedia(source: .url(url), mediaType: .photo, id: entry.id))
        }
        if entry.hasVideoComponent {
            let url = await backend.sourceURL(id: entry.id, type: .video)
            underlying.append(EncryptedMedia(source: .url(url), mediaType: .video, id: entry.id))
        }
        guard !underlying.isEmpty else { return nil }
        return try? InteractableMedia(underlyingMedia: underlying)
    }

    /// Media file URLs currently on disk, grouped by media id, from a cheap
    /// directory listing. The modification date is prefetched so the reconcile's
    /// in-place-edit check reads it from cache rather than issuing a fresh
    /// `stat` per file.
    ///
    /// iCloud placeholder stubs (`.<id>.<encext>.icloud`) ARE included here
    /// even though their last path extension is `icloud`: the enumerator
    /// matches on the middle extension (see
    /// `DataStorageModel.enumeratorForStorageDirectory`) precisely so
    /// `undownloadedMediaCount` can detect them via `pathExtension == "icloud"`.
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

    /// Number of media items in the album not yet downloaded from iCloud, from
    /// a cheap name-only directory scan — iCloud placeholders carry a `.icloud`
    /// path extension. Counts unique media ids across the whole album,
    /// independent of which pages the gallery has loaded.
    public func undownloadedMediaCount() -> Int {
        currentMediaURLsByID().values.reduce(into: 0) { count, urls in
            if urls.contains(where: { $0.pathExtension == "icloud" }) {
                count += 1
            }
        }
    }

    public static func deleteThumbnailDirectory() throws {
        try DiskFileAccess.deleteThumbnailDirectory()
    }

    // MARK: - Test hooks

    /// Test-only: exposes the backend chosen by `configure(for:)` so a test can
    /// assert which `MediaBackend` an album's storage option selects, and that
    /// exactly one is constructed.
    internal func _testBackend() -> (any MediaBackend)? {
        backend
    }

    /// Test-only: injects a backend (e.g. a `MediaBackendMock`) so the facade's
    /// index/paging layer can be exercised without a real disk or CloudKit account.
    internal func _testSetBackend(_ backend: any MediaBackend) {
        self.backend = backend
    }
}


