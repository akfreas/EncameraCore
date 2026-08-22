//
//  AlbumSizeBackfill.swift
//  EncameraCore
//
//  Fills the per-album size sidecar for albums that synced before the sidecar
//  existed — for an upgrading user that is every album, so without this the
//  storage screen reports zero iCloud bytes on first launch.
//

import Foundation

/// Reads an album's record sizes straight from CloudKit metadata, once, for albums
/// the sync path never measured.
///
/// Lazy by design: run when the storage screen asks for a breakdown, never at
/// launch. It fetches metadata only (`includeThumbnail: false`), so the lazy
/// `encBlob` asset is never requested, and it neither advances nor resets the
/// album's change token — a Settings screen's numbers are not worth re-downloading
/// the library's metadata over.
public actor AlbumSizeBackfill: DebugPrintable {

    private let makeStore: @Sendable (String) -> CloudKitMediaStoring

    public init(makeStore: @escaping @Sendable (String) -> CloudKitMediaStoring = { CloudKitStoreProvider.makeStore($0) }) {
        self.makeStore = makeStore
    }

    /// Bytes this album occupies in CloudKit, backfilling the sidecar first if it
    /// has never been measured.
    ///
    /// Returns `nil` when the figure is not knowable — a non-CloudKit album, no
    /// iCloud account, or a fetch that failed — which the caller renders as
    /// "unavailable" rather than as zero.
    ///
    /// - Throws: `CancellationError` if cancelled. The sidecar is left untouched in
    ///   that case, so the album is still marked as needing a backfill rather than
    ///   holding a partial total that reads as complete.
    public func cloudBytes(for album: Album,
                           store injectedStore: CloudKitMediaStoring? = nil,
                           sidecar injectedSidecar: AlbumSizeSidecar? = nil,
                           indexStore injectedIndex: MediaIndexStore? = nil) async throws -> Int64? {
        // `.local` albums have no CloudKit records, and `.icloud` (legacy iCloud
        // Drive) is excluded from the accounting model entirely. Neither may trigger
        // a fetch.
        guard album.storageOption == .cloudKit else { return nil }

        let sidecar = injectedSidecar ?? AlbumSizeSidecar(album: album)
        let indexStore = injectedIndex ?? MediaIndexStore(album: album)

        // "Total is zero" is not the signal — a genuinely empty album is zero too.
        // The gap is a sidecar that has never been backfilled and covers fewer
        // records than the index has components.
        let alreadyBackfilled = await sidecar.isBackfilled()
        let covered = await sidecar.recordCount()
        let components = await Self.indexComponentCount(indexStore)
        guard !alreadyBackfilled, covered < components else {
            return await sidecar.totalBytes()
        }

        let albumIDHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) ?? album.id
        let store = injectedStore ?? makeStore(albumIDHash)

        guard await store.accountAvailable() else {
            // No account means local-only, silently: no fetch, no error, and a
            // previously written sidecar still answers.
            return await sidecar.existsOnDisk() ? await sidecar.totalBytes() : nil
        }

        try Task.checkCancellation()
        let metadata: [CloudKitMediaMetadata]
        do {
            metadata = try await store.fetchMetadata(albumID: albumIDHash, includeThumbnail: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            printDebug("backfill FAILED albumIDHash=\(albumIDHash) — cloud size stays unknown raw=\(error)")
            return await sidecar.existsOnDisk() ? await sidecar.totalBytes() : nil
        }
        // Checked again after the fetch: writing here would leave a total that looks
        // complete when the walk was abandoned.
        try Task.checkCancellation()

        // The zone is shared across albums, so filter to this one's records.
        var sizes: [String: Int64] = [:]
        for record in metadata where record.albumID == albumIDHash {
            sizes[record.recordName] = record.sizeBytes
        }
        do {
            try await sidecar.replace(with: sizes, markBackfilled: true)
        } catch {
            printDebug("backfill sidecarWrite FAILED albumIDHash=\(albumIDHash) records=\(sizes.count) raw=\(error)")
            return sizes.values.reduce(0, +)
        }
        printDebug("backfill ok albumIDHash=\(albumIDHash) records=\(sizes.count)")
        return await sidecar.totalBytes()
    }

    /// How many CloudKit records the index implies: a Live Photo is one entry with
    /// two components, and therefore two records.
    private static func indexComponentCount(_ indexStore: MediaIndexStore) async -> Int {
        let entries = await indexStore.current()?.entries ?? []
        return entries.reduce(0) { total, entry in
            total + (entry.hasPhotoComponent ? 1 : 0) + (entry.hasVideoComponent ? 1 : 0)
        }
    }
}
