//
//  MediaIndexStore.swift
//  EncameraCore
//
//  Persists and loads a per-album media index. The index is a derived cache:
//  encrypted with the album key, stored in a local (never-synced) Application
//  Support directory, and always rebuildable from the album's encrypted files.
//

import Foundation
import CryptoKit
import Sodium

/// An in-memory snapshot of a per-album media index.
public struct MediaIndex: Sendable {
    public var entries: [MediaIndexEntry]

    public init(entries: [MediaIndexEntry]) {
        self.entries = entries
    }
}

/// Reads, writes, and (in later stages) rebuilds the per-album media index.
public actor MediaIndexStore {

    private let keyBytes: [UInt8]
    private let indexURL: URL

    /// In-memory snapshot of the album's index, loaded lazily. The store is the
    /// single owner of this cache: both backends mutate, persist, and read the
    /// index exclusively through here.
    private var cachedIndex: MediaIndex?
    /// Timestamp the cached copy was written for (locally or read from disk), so a
    /// newer on-disk write (e.g. a migration rebuild on another actor) is detected.
    private var cacheTimestamp: Date?
    /// Monotonic count of successful mutations (`apply`/`replace`) through this
    /// store. A long-running reconcile captures it before scanning and passes it
    /// to `replace(with:ifGenerationIs:)` so an incremental write that interleaved
    /// with the scan is detected instead of clobbered.
    private var generation: UInt64 = 0

    public init(album: Album) {
        self.keyBytes = album.key.keyBytes
        self.indexURL = Self.indexURL(for: album)
    }

    /// Direct initializer used by tests to exercise the store without a full `Album`.
    init(keyBytes: [UInt8], indexURL: URL) {
        self.keyBytes = keyBytes
        self.indexURL = indexURL
    }

    // MARK: - Load / Save

    /// Loads and decrypts the index, or returns `nil` if it is absent,
    /// unreadable, or corrupt — the caller should rebuild in that case.
    public func load() -> MediaIndex? {
        guard let fileData = try? Data(contentsOf: indexURL) else {
            return nil
        }
        guard
            let plaintext = try? Self.decrypt(fileData, keyBytes: keyBytes),
            let entries = try? MediaIndexCodec.decode(plaintext)
        else {
            return nil
        }
        return MediaIndex(entries: entries)
    }

    /// Encrypts and atomically writes the index to disk.
    public func save(_ index: MediaIndex) throws {
        let plaintext = MediaIndexCodec.encode(index.entries)
        let encrypted = try Self.encrypt(plaintext, keyBytes: keyBytes)
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encrypted.write(to: indexURL, options: .atomic)
        Self.excludeFromBackup(indexURL)
    }

    // MARK: - Stateful cache + mutation envelope

    /// Returns the in-memory index, loading it from disk on first access or when
    /// the on-disk file is newer than the cached copy (e.g. after a migration
    /// rebuild on a separate actor). Returns `nil` if no index has been built yet.
    /// Moved verbatim from `DiskMediaBackend.mediaIndex()`.
    public func current() -> MediaIndex? {
        if cachedIndex != nil {
            let diskDate = fileModificationDate()
            if let diskDate, let cacheDate = cacheTimestamp, diskDate > cacheDate {
                if let reloaded = load() {
                    cachedIndex = reloaded
                    cacheTimestamp = diskDate
                    return reloaded
                }
            }
            return cachedIndex
        }
        if let loaded = load() {
            cachedIndex = loaded
            // Use the index file's modification date — not `Date()` — so a newer
            // on-disk write is correctly detected as such on the next read.
            cacheTimestamp = fileModificationDate() ?? Date()
            return loaded
        }
        return nil
    }

    /// Reads the authoritative on-disk index, refreshing the cache from it. Used by
    /// the disk reconcile, which must diff against external writes rather than a
    /// possibly-stale warm cache.
    @discardableResult
    public func reloadFromDisk() -> MediaIndex? {
        guard let loaded = load() else { return nil }
        cachedIndex = loaded
        cacheTimestamp = fileModificationDate() ?? Date()
        return loaded
    }

    /// The single mutation primitive: load the current index (or empty), apply
    /// `body`, and save ONCE — but only when `body` actually changed the entries.
    /// On a successful save the cache advances to the new state; if the save throws
    /// the cache is left at its pre-mutation state (the Bug #14 rollback) and the
    /// error propagates. A `body` that changes nothing skips the save and the
    /// rewrite entirely (the no-op-save skip). Returns `body`'s result so callers
    /// can drive their own side effects (e.g. the gallery bus).
    @discardableResult
    public func apply<R>(_ body: (inout [MediaIndexEntry]) -> R) throws -> R {
        var index = current() ?? MediaIndex(entries: [])
        let before = index.entries
        let result = body(&index.entries)
        guard index.entries != before else { return result }
        try save(index)
        cachedIndex = index
        cacheTimestamp = fileModificationDate() ?? Date()
        generation += 1
        return result
    }

    /// Replace the whole index in one save (reconcile output / a full delta pass /
    /// deleteAll). Updates the cache on success; on a save failure the cache is left
    /// untouched and the error propagates.
    public func replace(with entries: [MediaIndexEntry]) throws {
        let index = MediaIndex(entries: entries)
        try save(index)
        cachedIndex = index
        cacheTimestamp = fileModificationDate() ?? Date()
        generation += 1
    }

    /// The mutation generation as of now — capture before a scan that will end in
    /// `replace(with:ifGenerationIs:)`.
    public func currentGeneration() -> UInt64 {
        generation
    }

    /// `replace` guarded by a generation check: writes only if no other mutation
    /// landed since the caller captured `expected`. Returns `false` — without
    /// saving — when the index moved on, so the caller re-diffs against the
    /// current state instead of clobbering the interleaved write.
    @discardableResult
    public func replace(with entries: [MediaIndexEntry], ifGenerationIs expected: UInt64) throws -> Bool {
        guard generation == expected else { return false }
        try replace(with: entries)
        return true
    }

    /// Folds entries into the index through the shared `upsert` algebra. Returns
    /// whether the index actually changed.
    @discardableResult
    public func upsert(_ entries: [MediaIndexEntry]) throws -> Bool {
        try apply { current in
            var changed = false
            for entry in entries {
                if current.upsert(entry) { changed = true }
            }
            return changed
        }
    }

    /// Drops whole entries by id (the disk delete/move fast path). Returns whether
    /// the index actually changed.
    @discardableResult
    public func remove(ids: Set<String>) throws -> Bool {
        try apply { $0.removeEntries(ids: ids) }
    }

    /// Clears a single component by record name (the per-component cloud path).
    /// Returns whether the whole entry was removed (`true`) versus a component
    /// merely cleared (`false`) — matching the shared algebra's signal.
    @discardableResult
    public func removeComponent(recordName: String) throws -> Bool {
        try apply { $0.removeComponent(recordName: recordName) }
    }

    // MARK: - File location

    /// `~/Library/Application Support/MediaIndex/` — a local, never-synced
    /// directory holding the derived index cache.
    public static func indexDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MediaIndex", isDirectory: true)
    }

    /// The index file for an album, named by a hash of the album id so the
    /// cleartext album name never appears on disk.
    static func indexURL(for album: Album) -> URL {
        let digest = SHA256.hash(data: Data(album.id.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return indexDirectoryURL().appendingPathComponent("\(hash).encindex")
    }

    /// Whether an index file already exists on disk for the album.
    public static func hasIndex(for album: Album) -> Bool {
        FileManager.default.fileExists(atPath: indexURL(for: album).path)
    }

    /// Synchronous count of entries in the album's index, or 0 if there is none.
    /// CloudKit albums keep authoritative membership in this index (not as files on
    /// disk), so counts must come from here, not a directory scan.
    public static func entryCount(for album: Album) -> Int {
        let url = indexURL(for: album)
        guard let data = try? Data(contentsOf: url),
              let plaintext = try? decrypt(data, keyBytes: album.key.keyBytes),
              let entries = try? MediaIndexCodec.decode(plaintext) else {
            return 0
        }
        return entries.count
    }

    /// Deletes the entire on-disk media index cache for all albums. The index
    /// is a derived cache and will be rebuilt by `MediaIndexMigration` on the
    /// next app launch. Debug-only; used to test the index build flow.
    public static func clearAllIndexes() throws {
        let dir = indexDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Returns the modification date of the on-disk index file, or `nil` if
    /// the file does not exist.
    public nonisolated func fileModificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date
    }

    // MARK: - Test hooks

    /// Test-only: the timestamp the warm cache was recorded for, so cache/reload
    /// tests can assert it tracks the on-disk mtime. Reachable via `@testable`.
    func _testCacheTimestamp() -> Date? { cacheTimestamp }

    /// Test-only: the warm in-memory cache, without triggering a load or reload,
    /// so a test can verify it is or isn't rolled back after a save failure.
    func _testCachedIndex() -> MediaIndex? { cachedIndex }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Encryption

    /// Encrypts an index blob with the album key. The layout — stream header
    /// followed by ciphertext — matches `EncryptedMetadataHandler`.
    static func encrypt(_ data: Data, keyBytes: [UInt8]) throws -> Data {
        let sodium = Sodium()
        guard let stream = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            throw MediaIndexError.encryptionFailed
        }
        let header = stream.header()
        guard let ciphertext = stream.push(message: Array(data), tag: .FINAL) else {
            throw MediaIndexError.encryptionFailed
        }
        var result = Data()
        result.reserveCapacity(header.count + ciphertext.count)
        result.append(contentsOf: header)
        result.append(contentsOf: ciphertext)
        return result
    }

    static func decrypt(_ data: Data, keyBytes: [UInt8]) throws -> Data {
        let headerSize = EncryptedFileFormat.streamHeaderSize
        guard data.count > headerSize else {
            throw MediaIndexError.decryptionFailed
        }
        let header = Array(data.prefix(headerSize))
        let ciphertext = Array(data.dropFirst(headerSize))
        let sodium = Sodium()
        guard let stream = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: header) else {
            throw MediaIndexError.decryptionFailed
        }
        guard let (plaintext, _) = stream.pull(cipherText: ciphertext) else {
            throw MediaIndexError.decryptionFailed
        }
        return Data(plaintext)
    }
}
