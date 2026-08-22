//
//  StorageUsageCalculator.swift
//  EncameraCore
//
//  The single entry point behind the Storage Insights screen: walks every root
//  Encamera writes to and returns a `StorageUsageBreakdown`. See
//  `Documentation/storage-accounting-model.md` for what each bucket means.
//

import Foundation

public actor StorageUsageCalculator: DebugPrintable {

    private let albumManager: AlbumManaging
    private let cache: CloudKitBlobCache
    private let backfill: AlbumSizeBackfill
    private let thumbnailDirectory: URL
    private let indexDirectory: URL
    /// Test seam: production reads the real per-album sidecar, a fixture supplies its
    /// own so the walk can be exercised without an Application Support directory.
    private let makeSidecar: @Sendable (Album) -> AlbumSizeSidecar

    /// Whether the last run's disk walk executed on the main thread. Nothing in the
    /// app reads this; `StorageUsageCalculatorTests` does, because "does not block
    /// the UI" is the one property of this type that no output value can prove.
    private var lastRunTouchedMainThread = false

    /// - Parameter cache: always `CloudKitBlobCache.shared` in production. A second
    ///   instance would report a divergent snapshot of the same directory.
    public init(albumManager: AlbumManaging,
                cache: CloudKitBlobCache = .shared,
                backfill: AlbumSizeBackfill = AlbumSizeBackfill(),
                thumbnailDirectory: URL = MediaPreviewStorage.directory,
                indexDirectory: URL = MediaIndexStore.indexDirectoryURL(),
                makeSidecar: @escaping @Sendable (Album) -> AlbumSizeSidecar = { AlbumSizeSidecar(album: $0) }) {
        self.albumManager = albumManager
        self.cache = cache
        self.backfill = backfill
        self.thumbnailDirectory = thumbnailDirectory
        self.indexDirectory = indexDirectory
        self.makeSidecar = makeSidecar
    }

    /// Measures every bucket.
    ///
    /// Hidden albums are counted. Excluding them would make the total silently
    /// under-report on any device that has one, with no way for the user to tell why
    /// the arithmetic does not add up — and since the screen shows byte counts only,
    /// counting a hidden album reveals nothing about it.
    ///
    /// - Throws: `CancellationError` when the caller walks away mid-walk. No partial
    ///   breakdown is returned; a half-measured total that reads as complete is worse
    ///   than no number.
    public func breakdown() async throws -> StorageUsageBreakdown {
        lastRunTouchedMainThread = Thread.isMainThread
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)

        var localMediaBytes: Int64 = 0
        var legacyICloudDriveAlbums = 0
        var cloudBytes: Int64 = 0
        var cloudBytesKnown = true

        for album in albums {
            try Task.checkCancellation()
            switch album.storageOption {
            case .local:
                localMediaBytes += try allocatedBytes(under: album.storageURL)
            case .icloud:
                // Excluded from every bucket by the accounting model; counted only so
                // the screen can say so rather than silently under-reporting.
                legacyICloudDriveAlbums += 1
            case .cloudKit:
                if let bytes = try await backfill.cloudBytes(for: album, sidecar: makeSidecar(album)) {
                    cloudBytes += bytes
                } else {
                    // One unknowable album makes the whole cloud figure unknowable: a
                    // partial sum rendered as a total is a lie, not an approximation.
                    cloudBytesKnown = false
                }
            }
        }

        try Task.checkCancellation()
        // Allocated size, not the in-memory index: the point of the disk-truth
        // accessor is that orphaned files still occupy the user's storage.
        let cachedCloudBytes = await cache.allocatedDiskBytes()

        try Task.checkCancellation()
        let thumbnailBytes = try allocatedBytes(under: thumbnailDirectory)

        try Task.checkCancellation()
        let indexBytes = try allocatedBytes(under: indexDirectory)

        let breakdown = StorageUsageBreakdown(
            localMediaBytes: localMediaBytes,
            cachedCloudBytes: cachedCloudBytes,
            thumbnailBytes: thumbnailBytes,
            indexBytes: indexBytes,
            cloudBytes: cloudBytesKnown ? cloudBytes : nil,
            legacyICloudDriveAlbumCount: legacyICloudDriveAlbums
        )
        // Byte counts only — never an album name, which would put cleartext in the logs.
        printDebug("breakdown ok albums=\(albums.count) device=\(breakdown.totalDeviceBytes) reclaimable=\(breakdown.reclaimableBytes) cloud=\(breakdown.cloudBytes.map(String.init) ?? "unavailable") legacyAlbums=\(legacyICloudDriveAlbums)")
        return breakdown
    }

    /// Bytes a directory tree occupies as the filesystem allocates them.
    ///
    /// Allocated rather than logical size, because that is what the device's free
    /// space actually reflects, and the two differ meaningfully across the many small
    /// encrypted files an album holds. A directory that does not exist contributes
    /// zero rather than throwing: `CloudKitStorageModel.baseURL` is a pure getter and
    /// may name a directory that was never created.
    private func allocatedBytes(under directory: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard FileManager.default.fileExists(atPath: directory.path),
              let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        var seen = 0
        for case let url as URL in enumerator {
            // Checked periodically rather than per file: a large album is tens of
            // thousands of files, and the check is not free.
            seen += 1
            if seen % 128 == 0 { try Task.checkCancellation() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Test hooks

    /// Test-only: whether the last walk ran on the main thread. Reachable via `@testable`.
    func _testRanOnMainThread() -> Bool { lastRunTouchedMainThread }
}
