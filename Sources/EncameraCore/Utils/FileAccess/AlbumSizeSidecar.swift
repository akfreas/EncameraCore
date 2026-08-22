//
//  AlbumSizeSidecar.swift
//  EncameraCore
//
//  Per-album record sizes, captured from CloudKit metadata as it syncs so
//  "how many bytes does this album hold in iCloud" is answerable offline and
//  instantly. See `Documentation/storage-accounting-model.md` for why this is a
//  sidecar rather than a field on `MediaIndexEntry`.
//

import Foundation
import CryptoKit

/// Byte sizes for one album's CloudKit records, keyed by **record name**
/// (`mediaID#<mediaTypeRawValue>`).
///
/// Keyed by record name and not `mediaID` because a Live Photo is two CloudKit
/// records with two sizes that collapse into a single `MediaIndexEntry`; keying by
/// `mediaID` would let one component silently overwrite the other's size.
///
/// A derived cache, like the media index it sits beside: it lives in the local,
/// never-synced `MediaIndex` directory, is excluded from backup, and a loss of it
/// costs a backfill rather than data. Contents are record names and integers — both
/// already exist in plaintext as CloudKit record names — so the file is not
/// encrypted; the album name never appears in it, and the filename is a hash.
public actor AlbumSizeSidecar {

    /// The on-disk shape. Versioned so a later field can be added without the
    /// unreadable-file fallback (which costs a backfill) firing on every album.
    private struct Payload: Codable {
        var version: Int = 1
        /// Set once a backfill has read every record for the album from CloudKit.
        /// Without it, an album whose index claims more components than the zone
        /// actually holds would look permanently under-covered and re-fetch its
        /// metadata on every visit to the storage screen.
        var backfilled: Bool = false
        var sizes: [String: Int64]
    }

    private let fileURL: URL
    private var sizes: [String: Int64]
    private var backfilled: Bool
    /// Whether the album has a sidecar on disk at all, which is what distinguishes
    /// "never captured" from "captured and genuinely empty" for the backfill.
    private var loadedFromDisk: Bool

    /// The sidecar file for an album, named by the same SHA-256 hash of the album id
    /// that `MediaIndexStore.indexURL(for:)` uses, so no cleartext album name
    /// reaches disk.
    public static func sidecarURL(for album: Album) -> URL {
        let digest = SHA256.hash(data: Data(album.id.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return MediaIndexStore.indexDirectoryURL().appendingPathComponent("\(hash).encsizes")
    }

    public init(album: Album) {
        self.init(fileURL: Self.sidecarURL(for: album))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            self.sizes = decoded.sizes
            self.backfilled = decoded.backfilled
            self.loadedFromDisk = true
        } else {
            self.sizes = [:]
            self.backfilled = false
            self.loadedFromDisk = false
        }
    }

    // MARK: - Read

    /// Total bytes this album occupies in CloudKit, summed over every record.
    public func totalBytes() -> Int64 {
        sizes.values.reduce(0, +)
    }

    /// How many records have a recorded size. The backfill compares this against the
    /// media index's component count to spot an album that predates the sidecar.
    public func recordCount() -> Int {
        sizes.count
    }

    public func bytes(forRecordName recordName: String) -> Int64? {
        sizes[recordName]
    }

    /// True when a sidecar file existed when this instance loaded. A file that
    /// exists and records nothing is a genuinely empty album; no file at all is an
    /// album that has never been measured.
    public func existsOnDisk() -> Bool {
        loadedFromDisk
    }

    /// True once a backfill has read the album's records straight from CloudKit, so
    /// the map is authoritative rather than whatever sync happened to observe.
    public func isBackfilled() -> Bool {
        backfilled
    }

    // MARK: - Write

    /// Merges `updates` in, drops `removals`, and persists once.
    ///
    /// Merge rather than wholesale replacement: the sync path applies a *delta*, so
    /// overwriting with only the changed records would zero every record the feed
    /// did not mention. The single write at the end matches the index's own
    /// save-once-per-sync durability shape.
    public func apply(updates: [String: Int64], removals: Set<String> = []) throws {
        guard !updates.isEmpty || !removals.isEmpty else { return }
        var merged = sizes
        for (recordName, bytes) in updates {
            merged[recordName] = max(0, bytes)
        }
        for recordName in removals {
            merged[recordName] = nil
        }
        try commit(merged, backfilled: backfilled)
    }

    /// Replaces the whole map — used by the backfill, which reads every record's
    /// size in one authoritative pass.
    public func replace(with newSizes: [String: Int64], markBackfilled: Bool = false) throws {
        try commit(newSizes.mapValues { max(0, $0) }, backfilled: backfilled || markBackfilled)
    }

    public func removeAll() throws {
        try commit([:], backfilled: false)
    }

    /// Persists first and adopts second, so a failed write leaves the in-memory map
    /// exactly as it was on disk. Keeping an unpersisted mutation would make
    /// `totalBytes()` report a figure that disappears on relaunch — the same reason
    /// `MediaIndexStore` rolls its warm cache back after a save failure.
    private func commit(_ newSizes: [String: Int64], backfilled newBackfilled: Bool) throws {
        let data = try JSONEncoder().encode(Payload(backfilled: newBackfilled, sizes: newSizes))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        excludeFromBackup()
        sizes = newSizes
        backfilled = newBackfilled
        loadedFromDisk = true
    }

    private func excludeFromBackup() {
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
