//
//  CloudKitBlobCacheTests.swift
//  EncameraCoreTests
//
//  The byte-cap eviction must never invalidate the URL `store` is about to
//  return: `ensureBlobLocal` deletes its download temp and hands that URL to
//  callers (`exportCiphertext`, the viewer), so a self-evicted entry turns every
//  oversized blob into an unopenable file and permanently blocks the
//  CloudKit -> local move for its album.
//

import XCTest
@testable import EncameraCore

final class CloudKitBlobCacheTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeCache(maxBytes: Int64) -> CloudKitBlobCache {
        CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache", isDirectory: true),
                          maxBytes: maxBytes)
    }

    private func sourceFile(bytes: Int) throws -> URL {
        let url = tempRoot.appendingPathComponent("source-\(UUID().uuidString)")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    func testStoreOfBlobLargerThanCapDoesNotEvictItself() async throws {
        // A single blob bigger than the whole cap (a few minutes of 4K video vs
        // the 500 MB default) can never fit — but the entry just stored is the one
        // the caller is being handed a URL to, so it must survive this pass.
        let cache = makeCache(maxBytes: 100)
        let url = try await cache.store(recordName: "big",
                                        changeTag: nil,
                                        albumID: "album",
                                        from: sourceFile(bytes: 150))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "store must never return a URL to a file its own eviction pass deleted")
        let cached = await cache.cachedURL(recordName: "big", changeTag: nil)
        XCTAssertNotNil(cached, "the just-stored entry must still be indexed")
    }

    func testOversizedStoreStillEvictsOlderEntries() async throws {
        // Protecting the just-stored entry must not turn the cap off: everything
        // ELSE is still evicted LRU-first to get as close to the cap as possible.
        let cache = makeCache(maxBytes: 100)
        _ = try await cache.store(recordName: "old",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 60))
        _ = try await cache.store(recordName: "big",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 150))

        let old = await cache.cachedURL(recordName: "old", changeTag: nil)
        XCTAssertNil(old, "older entries are still evicted to make room")
        let big = await cache.cachedURL(recordName: "big", changeTag: nil)
        XCTAssertNotNil(big)
    }

    func testStoreWithinCapEvictsLeastRecentlyUsedFirst() async throws {
        // The pre-existing LRU contract, pinned so the fix cannot regress it.
        let cache = makeCache(maxBytes: 100)
        _ = try await cache.store(recordName: "first",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 60))
        // Touch "first" so "second" becomes the LRU entry.
        _ = try await cache.store(recordName: "second",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 30))
        _ = await cache.cachedURL(recordName: "first", changeTag: nil)
        _ = try await cache.store(recordName: "third",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 30))

        let second = await cache.cachedURL(recordName: "second", changeTag: nil)
        XCTAssertNil(second, "the least-recently-used entry goes first")
        let first = await cache.cachedURL(recordName: "first", changeTag: nil)
        XCTAssertNotNil(first)
        let third = await cache.cachedURL(recordName: "third", changeTag: nil)
        XCTAssertNotNil(third)
    }

    // MARK: - Disk truth

    /// The cache directory as an outside observer sees it, so a test never grades
    /// the cache against its own bookkeeping.
    private func measureCacheDirectory() throws -> (logical: Int64, files: Int) {
        let root = tempRoot.appendingPathComponent("cache", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var count = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, url.lastPathComponent != ".cacheindex.json" else { continue }
            bytes += Int64(values.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    /// Writes a blob into an album folder without going through the actor — the
    /// on-disk shape a failed eviction leaves behind.
    @discardableResult
    private func plantOrphan(albumID: String, recordName: String, bytes: Int) throws -> URL {
        let folder = tempRoot.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(CloudKitBlobCache.albumFolderName(albumID), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(recordName)
        try Data(repeating: 0xCD, count: bytes).write(to: url)
        return url
    }

    /// The exact gap that makes a storage screen lie: bytes on disk that the
    /// in-memory index does not know about.
    func testDiskBytesCountsFilesMissingFromTheIndex() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "tracked", changeTag: nil, albumID: "album",
                                  from: sourceFile(bytes: 40))
        try plantOrphan(albumID: "album", recordName: "orphan", bytes: 60)

        let tracked = await cache.totalBytes()
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(tracked, 40, "The in-memory figure only knows what it stored")
        XCTAssertEqual(onDisk, 100, "Disk truth includes the untracked file")
        XCTAssertEqual(onDisk, try measureCacheDirectory().logical,
                       "And matches an independent measurement of the directory")
    }

    func testReconcileReportsOrphanedFiles() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "tracked", changeTag: nil, albumID: "album",
                                  from: sourceFile(bytes: 40))
        try plantOrphan(albumID: "album", recordName: "orphan", bytes: 60)

        let result = await cache.reconcile()
        XCTAssertEqual(result.orphanedFiles, 1)
        XCTAssertEqual(result.orphanedBytes, 60)

        let tracked = await cache.totalBytes()
        XCTAssertEqual(tracked, 100, "An adopted orphan counts against the cap from now on")
        let again = await cache.reconcile()
        XCTAssertEqual(again.orphanedFiles, 0, "Adoption is idempotent")
    }

    /// After a failed eviction the file is still there, so its bytes must still
    /// count — otherwise the cache reports less than it occupies.
    func testFailedEvictionKeepsTheEntryAndItsBytes() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "stuck", changeTag: nil, albumID: "album",
                                  from: sourceFile(bytes: 80))
        let albumDir = tempRoot.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(CloudKitBlobCache.albumFolderName("album"), isDirectory: true)
        // A read-only parent directory makes `removeItem` fail while the file lives on.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: albumDir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: albumDir.path)
        }

        await cache.evict(recordName: "stuck")

        let total = await cache.totalBytes()
        XCTAssertEqual(total, 80, "A file that survived eviction keeps counting")
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(onDisk, 80)
    }

    func testDiskBytesMatchesTotalBytesWhenTheCacheIsConsistent() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "a", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40))
        _ = try await cache.store(recordName: "b", changeTag: nil, albumID: "other", from: sourceFile(bytes: 70))

        let total = await cache.totalBytes()
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(total, 110)
        XCTAssertEqual(onDisk, total, "The two figures may only differ by orphans")
    }

    /// Allocated size is block-rounded, so it is never smaller than the logical
    /// size — which is why the storage screen reports it rather than the other one.
    func testAllocatedDiskBytesIsNeverLessThanLogicalBytes() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "a", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40))

        let logical = await cache.diskBytes()
        let allocated = await cache.allocatedDiskBytes()
        XCTAssertGreaterThanOrEqual(allocated, logical)
    }

    func testClearAllZeroesBothFigures() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "a", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40))
        try plantOrphan(albumID: "album", recordName: "orphan", bytes: 60)

        try await cache.clearAll()

        let total = await cache.totalBytes()
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(total, 0)
        XCTAssertEqual(onDisk, 0, "Including the files the index never knew about")
        XCTAssertEqual(try measureCacheDirectory().files, 0)
    }
}
