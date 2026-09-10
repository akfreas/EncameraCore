//
//  CloudKitBlobCache.swift
//  EncameraCore
//
//  The app-controlled, evictable local cache for CloudKit blobs — the lever
//  Option A unlocks ("iCloud is the backend, local is an evictable cache",
//  decision doc §3). Holds the *encrypted* ENC2 file only; it is re-fetchable
//  and never the source of truth, so it lives under Caches and is excluded from
//  backup. `.local` albums never touch this cache.
//

import Foundation
import CryptoKit

public actor CloudKitBlobCache: DebugPrintable {

    /// Per-album residency policy for fetched blobs.
    public enum Mode: Sendable {
        case keepLocal     // authoring device / opted-in: keep the file resident
        case fetchOnTap    // non-authoring device default: evictable on pressure
    }

    private struct Entry: Codable {
        let changeTag: String?
        /// Path relative to `baseDir`, so the cache survives a Caches relocation.
        let relativePath: String
        let size: Int64
        var lastAccess: Date
    }

    private let baseDir: URL
    private let maxBytes: Int64
    private var index: [String: Entry] = [:]
    /// Times the index sidecar has been persisted. A batched operation is held to
    /// one write however many records it touches.
    private(set) var indexPersistCount = 0

    private var indexFileURL: URL { baseDir.appendingPathComponent(".cacheindex.json") }
    private func url(for entry: Entry) -> URL { baseDir.appendingPathComponent(entry.relativePath) }

    public static var defaultBaseDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("CloudKitBlobs", isDirectory: true)
    }

    /// The process-wide cache. All coordinators share ONE instance so the on-disk
    /// `.cacheindex.json` has a single in-memory owner — separate instances writing
    /// it from divergent snapshots would clobber each other.
    public static let shared = CloudKitBlobCache()

    public init(baseDir: URL = CloudKitBlobCache.defaultBaseDir,
                maxBytes: Int64 = 500 * 1024 * 1024) {
        self.baseDir = baseDir
        self.maxBytes = maxBytes
        loadIndex()
    }

    /// Filesystem-safe per-album folder name derived from the (base64, possibly
    /// slash-containing) `albumID`. Used by BOTH the cache and `CloudKitStorageModel`
    /// so they agree on one tree (no duplicate copies, no path divergence).
    public static func albumFolderName(_ albumID: String) -> String {
        let digest = SHA256.hash(data: Data(albumID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lookup

    /// The cached file for `recordName`, but only if its `changeTag` matches the
    /// caller's expectation. A server-side change (new tag) invalidates the stale
    /// copy — CloudKit gives no durable "won't re-download" guarantee, so we own
    /// dedup (decision doc §5).
    ///
    /// A `nil` expectation means the caller has observed no tag yet (e.g. a fresh
    /// launch before delta sync repopulates its in-memory tag map) — trust the
    /// persisted entry rather than re-downloading everything; the next sync
    /// supplies a real tag and evicts genuinely stale copies via the mismatch.
    public func cachedURL(recordName: String, changeTag: String?) -> URL? {
        // Three very different causes used to collapse into a bare `nil` here:
        // never cached, cached-but-stale, and cached-but-file-vanished. Each gets
        // its own message so a spurious re-download is attributable.
        guard var entry = index[recordName] else {
            printDebug("cachedURL MISS recordName=\(recordName) reason=notIndexed indexCount=\(index.count)")
            return nil
        }
        if let changeTag, entry.changeTag != changeTag {
            printDebug("cachedURL MISS recordName=\(recordName) reason=staleTag cachedTag=\(entry.changeTag ?? "nil") wantTag=\(changeTag)")
            return nil
        }
        let fileURL = url(for: entry)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            printDebug("cachedURL MISS recordName=\(recordName) reason=fileMissingOnDisk file=\(fileURL.lastPathComponent) sizeBytes=\(entry.size); dropping index entry")
            index[recordName] = nil
            return nil
        }
        entry.lastAccess = Date()
        index[recordName] = entry
        printDebug("cachedURL hit recordName=\(recordName) sizeBytes=\(entry.size) changeTag=\(entry.changeTag ?? "nil")")
        return fileURL
    }

    /// The size of the cached file for `recordName`, under the same change-tag
    /// rules as `cachedURL` but without touching the entry: no `lastAccess` bump,
    /// no index write, no log. A caller that only wants to report bytes — the
    /// storage figure on the info screen, summed over every chunk of a video —
    /// must not reorder the LRU that `enforceCap` evicts on.
    ///
    /// `nil` when the entry's file is gone: a size is shown to the user as a local
    /// copy they can reclaim, so bytes that are not on disk must not be reported.
    /// The entry is left in place — dropping it is a write, and `cachedURL` on the
    /// fetch path is where that self-heal belongs.
    public func cachedSize(recordName: String, changeTag: String?) -> Int64? {
        guard let entry = index[recordName] else { return nil }
        if let changeTag, entry.changeTag != changeTag { return nil }
        guard FileManager.default.fileExists(atPath: url(for: entry).path) else { return nil }
        return entry.size
    }

    // MARK: - Store

    /// Copy `sourceURL` into the cache for `recordName`, replacing any prior copy,
    /// then enforce the size cap by LRU eviction. Returns the cached URL.
    @discardableResult
    public func store(recordName: String,
                      changeTag: String?,
                      albumID: String,
                      from sourceURL: URL) throws -> URL {
        try store(recordName: recordName, changeTag: changeTag, albumID: albumID,
                  source: sourceURL, consumingSource: false)
    }

    /// Same as `store(from:)`, but consumes `sourceURL`: a caller that already owns
    /// the bytes on disk hands the file over instead of paying for a second copy of
    /// it. The source is gone afterwards on the move path; on the cross-volume
    /// fallback it is copied and left for the caller to remove.
    @discardableResult
    public func store(recordName: String,
                      changeTag: String?,
                      albumID: String,
                      moving sourceURL: URL) throws -> URL {
        try store(recordName: recordName, changeTag: changeTag, albumID: albumID,
                  source: sourceURL, consumingSource: true)
    }

    private func store(recordName: String,
                       changeTag: String?,
                       albumID: String,
                       source sourceURL: URL,
                       consumingSource: Bool) throws -> URL {
        let albumFolder = Self.albumFolderName(albumID)
        let albumDir = baseDir.appendingPathComponent(albumFolder, isDirectory: true)
        printDebug("store start recordName=\(recordName) changeTag=\(changeTag ?? "nil") albumFolder=\(albumFolder) source=\(sourceURL.lastPathComponent)")
        do {
            try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
        } catch {
            printDebug("store FAILED recordName=\(recordName) stage=createAlbumDir albumFolder=\(albumFolder) raw=\(error)")
            throw error
        }

        if let existing = index[recordName] {
            // Swallowed by design (a missing prior copy is fine), but a real
            // failure here leaves an orphan file outside the byte cap.
            do {
                try FileManager.default.removeItem(at: url(for: existing))
                printDebug("store replace recordName=\(recordName) removedPriorSizeBytes=\(existing.size) priorTag=\(existing.changeTag ?? "nil")")
            } catch {
                printDebug("store WARNING recordName=\(recordName) could not remove prior cached copy file=\(url(for: existing).lastPathComponent) raw=\(error)")
            }
        }
        var destURL = albumDir.appendingPathComponent(recordName)
        if FileManager.default.fileExists(atPath: destURL.path) {
            do {
                try FileManager.default.removeItem(at: destURL)
            } catch {
                printDebug("store FAILED recordName=\(recordName) stage=removeExistingDest file=\(destURL.lastPathComponent) raw=\(error)")
                throw error
            }
        }
        do {
            try Self.placeFile(from: sourceURL, at: destURL, consumingSource: consumingSource)
        } catch {
            printDebug("store FAILED recordName=\(recordName) stage=copyIn source=\(sourceURL.lastPathComponent) raw=\(error)")
            throw error
        }
        excludeFromBackup(&destURL)

        let attributes = try? FileManager.default.attributesOfItem(atPath: destURL.path)
        if attributes == nil {
            // The copy above succeeded, so an unreadable destination means the file
            // is gone/inaccessible already — the entry would then record size 0 and
            // escape the byte cap forever.
            printDebug("store WARNING recordName=\(recordName) could not read attributes of just-copied file=\(destURL.lastPathComponent); recording sizeBytes=0")
        }
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        index[recordName] = Entry(changeTag: changeTag,
                                  relativePath: "\(albumFolder)/\(recordName)",
                                  size: size,
                                  lastAccess: Date())
        printDebug("store ok recordName=\(recordName) sizeBytes=\(size) changeTag=\(changeTag ?? "nil") cacheTotalBytes=\(totalBytes()) entries=\(index.count)")
        enforceCap(protecting: recordName)
        persist()
        return destURL
    }

    // MARK: - Eviction

    public func evict(recordName: String) {
        guard index[recordName] != nil else {
            printDebug("evict skip recordName=\(recordName) reason=notIndexed")
            return
        }
        removeCachedFile(recordName: recordName, context: "evict")
        persist()
    }

    /// Evicts every named record, then writes the index once.
    ///
    /// The chunks of one video are thousands of records; evicting them one at a
    /// time re-encodes and rewrites the whole sidecar per chunk, serialized on this
    /// actor. Every removal is attempted whatever the ones before it did, and the
    /// single write happens either way — an index still describing files that are
    /// gone is the failure this replaces.
    public func evict(recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        var evicted = 0
        var freedBytes: Int64 = 0
        for recordName in recordNames {
            guard let size = index[recordName]?.size else { continue }
            if removeCachedFile(recordName: recordName, context: "evictBatch") {
                evicted += 1
                freedBytes += size
            }
        }
        printDebug("evictBatch ok requested=\(recordNames.count) evicted=\(evicted) freedBytes=\(freedBytes) remainingEntries=\(index.count)")
        persist()
    }

    /// Removes one entry's file and untracks it, without persisting. Returns
    /// whether the entry was dropped: a file that survives a failed remove keeps
    /// its entry and its bytes in the total — the posture `enforceCap` already
    /// takes. Dropping the entry there used to leave the file on disk with nothing
    /// tracking it, so the cache reported fewer bytes than it occupied.
    @discardableResult
    private func removeCachedFile(recordName: String, context: String) -> Bool {
        guard let entry = index[recordName] else { return false }
        let fileURL = url(for: entry)
        do {
            try FileManager.default.removeItem(at: fileURL)
            index[recordName] = nil
            printDebug("\(context) ok recordName=\(recordName) sizeBytes=\(entry.size) remainingEntries=\(index.count)")
            return true
        } catch {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                printDebug("\(context) WARNING recordName=\(recordName) file remove failed, keeping entry file=\(fileURL.lastPathComponent) raw=\(error)")
                return false
            }
            index[recordName] = nil
            printDebug("\(context) ok recordName=\(recordName) file already missing, dropping entry")
            return true
        }
    }

    public func evictAll(olderThan date: Date) {
        var evicted = 0
        var freedBytes: Int64 = 0
        for (recordName, entry) in index where entry.lastAccess < date {
            let fileURL = url(for: entry)
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                // Same posture as `evict` and `enforceCap`: a surviving file keeps its
                // entry, so its bytes keep counting instead of leaking untracked.
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    printDebug("evictAll WARNING recordName=\(recordName) file remove failed, keeping entry file=\(fileURL.lastPathComponent) raw=\(error)")
                    continue
                }
                printDebug("evictAll recordName=\(recordName) file already missing, dropping entry")
            }
            index[recordName] = nil
            evicted += 1
            freedBytes += entry.size
        }
        printDebug("evictAll ok olderThan=\(date) evicted=\(evicted) freedBytes=\(freedBytes) remainingEntries=\(index.count) cacheTotalBytes=\(totalBytes())")
        persist()
    }

    /// The fast in-memory figure, summed over index entries. Deliberately does no
    /// filesystem I/O: `store` calls it on every upload, and a directory walk there
    /// would put an enumeration in the hot path.
    public func totalBytes() -> Int64 {
        index.values.reduce(0) { $0 + $1.size }
    }

    /// Actual bytes the cache occupies on disk, including files the in-memory index
    /// knows nothing about.
    ///
    /// Logical file size, the same measure `store` records into an entry — so this
    /// and `totalBytes()` agree exactly on a consistent cache, and any difference
    /// between them is orphaned files rather than a unit mismatch. The
    /// `.cacheindex.json` sidecar is excluded: it is bookkeeping, not cached media,
    /// and counting it would make the two figures differ by a few hundred bytes for
    /// no useful reason. Use `allocatedDiskBytes()` for what the user's free space
    /// actually reflects.
    public func diskBytes() -> Int64 {
        enumerateCacheFiles().reduce(0) { $0 + $1.logicalSize }
    }

    /// Bytes the cache occupies as the filesystem allocates them — block-rounded,
    /// and therefore what the device's free space actually reflects. This is the
    /// figure the storage screen reports; `diskBytes()` is the one that must agree
    /// with the index.
    public func allocatedDiskBytes() -> Int64 {
        enumerateCacheFiles().reduce(0) { $0 + $1.allocatedSize }
    }

    /// Adopts files under `baseDir` that no index entry claims, so their bytes count
    /// against the cap and LRU eviction can eventually reclaim them.
    ///
    /// Adopting rather than deleting: an orphan is real cached ciphertext that a
    /// reader may still want, and its only defect is bookkeeping. Adopted entries
    /// carry no change tag (so the next tag check re-fetches rather than trusting
    /// them) and inherit the file's modification date as `lastAccess`, which puts
    /// them at the front of the LRU queue where an untracked file belongs.
    @discardableResult
    public func reconcile() -> (orphanedBytes: Int64, orphanedFiles: Int) {
        let claimed = Set(index.values.map { $0.relativePath })
        var orphanedBytes: Int64 = 0
        var orphanedFiles = 0
        for file in enumerateCacheFiles() where !claimed.contains(file.relativePath) {
            orphanedBytes += file.logicalSize
            orphanedFiles += 1
            index[file.recordName] = Entry(changeTag: nil,
                                           relativePath: file.relativePath,
                                           size: file.logicalSize,
                                           lastAccess: file.modified)
        }
        if orphanedFiles > 0 {
            printDebug("reconcile adopted orphanedFiles=\(orphanedFiles) orphanedBytes=\(orphanedBytes) entries=\(index.count)")
            persist()
        }
        return (orphanedBytes, orphanedFiles)
    }

    private struct CacheFile {
        let relativePath: String
        let recordName: String
        let logicalSize: Int64
        let allocatedSize: Int64
        let modified: Date
    }

    /// Every cached blob under `baseDir`, excluding the index sidecar. An absent
    /// directory enumerates as nothing, which is the right answer for a cache that
    /// has never been written.
    private func enumerateCacheFiles() -> [CacheFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey,
                                      .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: baseDir,
                                                             includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]) else {
            return []
        }
        let basePath = baseDir.standardizedFileURL.path
        var files: [CacheFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            guard url.lastPathComponent != indexFileURL.lastPathComponent else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(basePath + "/") else { continue }
            let relativePath = String(path.dropFirst(basePath.count + 1))
            files.append(CacheFile(relativePath: relativePath,
                                   recordName: url.lastPathComponent,
                                   logicalSize: Int64(values.fileSize ?? 0),
                                   allocatedSize: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                                   modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)))
        }
        return files
    }

    /// Wipes the entire on-disk cache (every album folder and the `.cacheindex.json`
    /// sidecar) and clears the in-memory index. Used by "Erase All Data" so no
    /// cached ciphertext blobs survive a full reset.
    ///
    /// Throws on failure: a swallowed error here meant "Erase All Data" could leave
    /// cached ciphertext blobs on disk while the in-memory index reported them gone.
    /// The index is cleared only after the on-disk removal actually succeeded, so it
    /// keeps tracking whatever survived a failed erase.
    public func clearAll() throws {
        let entryCount = index.count
        let bytes = totalBytes()
        guard FileManager.default.fileExists(atPath: baseDir.path) else {
            index.removeAll()
            printDebug("clearAll ok (nothing on disk) entries=\(entryCount)")
            return
        }
        do {
            try FileManager.default.removeItem(at: baseDir)
            printDebug("clearAll ok entries=\(entryCount) bytes=\(bytes)")
        } catch {
            printDebug("clearAll FAILED entries=\(entryCount) bytes=\(bytes) dir=\(baseDir.lastPathComponent) raw=\(error)")
            throw error
        }
        index.removeAll()
    }

    // MARK: - Internals

    /// `protecting` names the entry `store` just wrote and is about to return a
    /// URL for. A blob larger than the whole cap would otherwise be evicted by
    /// its own store's pass (it has the newest `lastAccess`, but the loop only
    /// stops when the total fits), handing the caller a dead URL — which breaks
    /// viewing any oversized item and permanently blocks the CloudKit -> local
    /// move for its album. The cache may briefly exceed the cap by that one
    /// entry; the next store's pass evicts it once it is no longer the newest.
    private func enforceCap(protecting protected: String? = nil) {
        guard maxBytes > 0 else { return }
        var total = totalBytes()
        guard total > maxBytes else { return }
        // Evict least-recently-used first.
        let ordered = index.sorted { $0.value.lastAccess < $1.value.lastAccess }
        printDebug("enforceCap start totalBytes=\(total) maxBytes=\(maxBytes) entries=\(index.count)")
        for (recordName, entry) in ordered {
            if total <= maxBytes { break }
            if recordName == protected { continue }
            let fileURL = url(for: entry)
            do {
                try FileManager.default.removeItem(at: fileURL)
                printDebug("enforceCap evict recordName=\(recordName) sizeBytes=\(entry.size) lastAccess=\(entry.lastAccess)")
            } catch {
                // A file that still exists after a failed remove keeps its index
                // entry and its bytes in the running total — dropping either would
                // make the accounting optimistic and let the cache exceed maxBytes
                // on disk indefinitely. An already-missing file is safe to untrack.
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    printDebug("enforceCap WARNING recordName=\(recordName) file remove failed, keeping entry file=\(fileURL.lastPathComponent) raw=\(error)")
                    continue
                }
                printDebug("enforceCap evict recordName=\(recordName) file already missing, dropping entry")
            }
            index[recordName] = nil
            total -= entry.size
        }
        printDebug("enforceCap ok totalBytes=\(total) entries=\(index.count)")
    }

    /// Puts `source`'s bytes at `destination`, moving when the caller has given the
    /// file up. `moveItem` fails across volumes where `copyItem` succeeds, so a
    /// failed move falls back to a copy rather than failing the store — the caller
    /// deletes its source either way.
    private static func placeFile(from source: URL, at destination: URL, consumingSource: Bool) throws {
        guard consumingSource else {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            printDebug("store move fell back to copy source=\(source.lastPathComponent) raw=\(error)")
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func excludeFromBackup(_ url: inout URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            // Non-fatal, but it means re-fetchable ciphertext is being backed up.
            printDebug("excludeFromBackup WARNING file=\(url.lastPathComponent) raw=\(error)")
        }
    }

    // MARK: - Persistence (survive relaunch)

    /// Rebuild the in-memory index from the on-disk sidecar, dropping entries whose
    /// file no longer exists. Without this, a relaunch re-downloads everything and
    /// orphans on-disk files outside the byte cap.
    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFileURL) else {
            // Absent sidecar is normal on first launch; a read failure on an
            // existing file is not, and costs a full re-download of the album.
            let exists = FileManager.default.fileExists(atPath: indexFileURL.path)
            printDebug("loadIndex \(exists ? "FAILED" : "skip") reason=\(exists ? "sidecarUnreadable" : "noSidecar") file=\(indexFileURL.lastPathComponent)")
            return
        }
        guard let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            printDebug("loadIndex FAILED reason=decodeError bytes=\(data.count) file=\(indexFileURL.lastPathComponent); starting with an empty cache index")
            return
        }
        index = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0.value).path) }
        // A large gap between decoded and kept means files were reaped underneath
        // us (Caches purge) and everything in the gap will be re-downloaded.
        printDebug("loadIndex ok decoded=\(decoded.count) kept=\(index.count) droppedMissingFiles=\(decoded.count - index.count) cacheTotalBytes=\(totalBytes())")
    }

    private func persist() {
        indexPersistCount += 1
        guard let data = try? JSONEncoder().encode(index) else {
            printDebug("persist FAILED reason=encodeError entries=\(index.count)")
            return
        }
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            printDebug("persist WARNING could not create cache dir=\(baseDir.lastPathComponent) raw=\(error); attempting the write anyway")
        }
        do {
            try data.write(to: indexFileURL)
        } catch {
            // A failed write means the next launch reads a stale sidecar: entries
            // stored since the last good persist look uncached and re-download.
            printDebug("persist FAILED entries=\(index.count) bytes=\(data.count) file=\(indexFileURL.lastPathComponent) raw=\(error)")
        }
    }
}
