import XCTest
@testable import EncameraCore

final class CachedChunkedBlobStoreTests: XCTestCase {

    private var cacheDir: URL!
    private var stagingDir: URL!
    private var cache: CloudKitBlobCache!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cached-chunk-tests-\(id)", isDirectory: true)
        stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cached-chunk-staging-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        cache = CloudKitBlobCache(baseDir: cacheDir, maxBytes: 100 * 1024 * 1024)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.removeItem(at: stagingDir)
    }

    // MARK: - Stale chunk validation

    /// A nil validationTag must NOT match a cached entry whose changeTag is set.
    /// This is the bug: a post-relaunch CachedChunkedBlobStore gets validationTag
    /// nil (the in-memory changeTags map is empty), and the cache serves stale
    /// chunks from a previous upload — the AAD's fileID rejects them as a
    /// decryption error instead of a clean cache miss.
    func testNilValidationTagRejectsCachedChunksFromAPriorUpload() async throws {
        let staleData = Data("stale-chunk-v1".utf8)
        let freshData = Data("fresh-chunk-v2".utf8)
        let chunkRecordName = ChunkedBlobSchema.chunkRecordName(mediaRecordName: "media-1", index: 0)

        // Simulate a prior session: cache a chunk under a known changeTag.
        let staging = stagingDir.appendingPathComponent("stale.bin")
        try staleData.write(to: staging)
        try await cache.store(recordName: chunkRecordName,
                              changeTag: "tag-v1",
                              albumID: "album-1",
                              from: staging)

        // Verify the cache hit exists when the tag matches.
        let hitURL = await cache.cachedURL(recordName: chunkRecordName, changeTag: "tag-v1")
        XCTAssertNotNil(hitURL, "sanity: cache should hit when tags match")

        // Post-relaunch: validationTag is nil because changeTags map is empty.
        let stub = StubChunkStore(chunkData: freshData)
        let cachedStore = CachedChunkedBlobStore(store: stub,
                                                  cache: cache,
                                                  albumID: "album-1",
                                                  validationTag: nil)

        let fetched = try await cachedStore.fetchChunk(mediaRecordName: "media-1", index: 0)

        // The correct behavior: nil tag should NOT serve a tagged cache entry.
        // It must fall through to the underlying store and return fresh data.
        XCTAssertEqual(fetched, freshData,
                       "nil validationTag must not serve stale cached chunks — should fetch fresh from the store")
        let fetchCount1 = await stub.fetches.count
        XCTAssertEqual(fetchCount1, 1,
                       "the underlying store should have been called exactly once")
    }

    /// When the validationTag matches the cached entry, the cache should be used.
    func testMatchingValidationTagServesCachedChunks() async throws {
        let cachedData = Data("cached-chunk".utf8)
        let chunkRecordName = ChunkedBlobSchema.chunkRecordName(mediaRecordName: "media-1", index: 0)

        let staging = stagingDir.appendingPathComponent("cached.bin")
        try cachedData.write(to: staging)
        try await cache.store(recordName: chunkRecordName,
                              changeTag: "tag-v1",
                              albumID: "album-1",
                              from: staging)

        let stub = StubChunkStore(chunkData: Data("should-not-be-fetched".utf8))
        let cachedStore = CachedChunkedBlobStore(store: stub,
                                                  cache: cache,
                                                  albumID: "album-1",
                                                  validationTag: "tag-v1")

        let fetched = try await cachedStore.fetchChunk(mediaRecordName: "media-1", index: 0)

        XCTAssertEqual(fetched, cachedData, "matching tag should serve from cache")
        let fetchCount2 = await stub.fetches.count
        XCTAssertEqual(fetchCount2, 0, "underlying store should not be called for a cache hit")
    }

    /// A mismatched (non-nil) validationTag should reject the cached entry.
    func testMismatchedValidationTagRejectsCachedChunks() async throws {
        let staleData = Data("stale-chunk-v1".utf8)
        let freshData = Data("fresh-chunk-v2".utf8)
        let chunkRecordName = ChunkedBlobSchema.chunkRecordName(mediaRecordName: "media-1", index: 0)

        let staging = stagingDir.appendingPathComponent("stale.bin")
        try staleData.write(to: staging)
        try await cache.store(recordName: chunkRecordName,
                              changeTag: "tag-v1",
                              albumID: "album-1",
                              from: staging)

        let stub = StubChunkStore(chunkData: freshData)
        let cachedStore = CachedChunkedBlobStore(store: stub,
                                                  cache: cache,
                                                  albumID: "album-1",
                                                  validationTag: "tag-v2")

        let fetched = try await cachedStore.fetchChunk(mediaRecordName: "media-1", index: 0)

        XCTAssertEqual(fetched, freshData, "mismatched tag should bypass cache")
        let fetchCount3 = await stub.fetches.count
        XCTAssertEqual(fetchCount3, 1)
    }

    // MARK: - Cache fill cost

    /// A cache miss must consume the file the store already staged, not re-serialize
    /// the bytes into a second file and copy that in. Same inode as the staged file
    /// proves the cached copy IS that file (a copy — APFS clone included — allocates
    /// a new one), and the staged path being gone proves nothing leaked.
    func testCacheMissMovesTheStagedFileInsteadOfRewritingIt() async throws {
        let chunkData = Data(repeating: 0xAB, count: 64 * 1024)
        let chunkRecordName = ChunkedBlobSchema.chunkRecordName(mediaRecordName: "media-1", index: 0)
        let stub = StagingChunkStore(chunkData: chunkData, stagingDir: stagingDir)
        let cachedStore = CachedChunkedBlobStore(store: stub,
                                                 cache: cache,
                                                 albumID: "album-1",
                                                 validationTag: "tag-v1")

        let fetched = try await cachedStore.fetchChunk(mediaRecordName: "media-1", index: 0)
        XCTAssertEqual(fetched, chunkData)

        let cachedURL = try await waitForCachedURL(recordName: chunkRecordName, changeTag: "tag-v1")

        let staged = try XCTUnwrap(stub.staged.first)
        XCTAssertEqual(Self.fileIdentity(cachedURL), staged.identity,
                       "the cached file must be the staged file itself — a differing inode means the bytes were written a second time")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path),
                       "the staged file must not survive the store — one leaked file per chunk is worse than the extra copy")
        XCTAssertEqual(try Data(contentsOf: cachedURL), chunkData,
                       "the cached bytes must equal the fetched bytes")
    }

    /// The cached file a miss produced must serve the next fetch, byte for byte,
    /// without touching the underlying store.
    func testChunkMovedIntoTheCacheServesTheNextFetch() async throws {
        let chunkData = Data(repeating: 0x5C, count: 12 * 1024)
        let chunkRecordName = ChunkedBlobSchema.chunkRecordName(mediaRecordName: "media-1", index: 3)
        let stub = StagingChunkStore(chunkData: chunkData, stagingDir: stagingDir)
        let cachedStore = CachedChunkedBlobStore(store: stub,
                                                 cache: cache,
                                                 albumID: "album-1",
                                                 validationTag: "tag-v1")

        _ = try await cachedStore.fetchChunk(mediaRecordName: "media-1", index: 3)
        _ = try await waitForCachedURL(recordName: chunkRecordName, changeTag: "tag-v1")

        let second = try await cachedStore.fetchChunk(mediaRecordName: "media-1", index: 3)
        XCTAssertEqual(second, chunkData, "the second fetch must serve the same bytes from the cache")
        XCTAssertEqual(stub.fetchCount, 1, "the second fetch must not reach the underlying store")
    }

    /// Caching is best-effort: a cache that cannot accept the file must not fail the
    /// fetch, and must not leave the staged file behind either.
    func testChunkIsReturnedAndStagedFileRemovedWhenTheCacheStoreFails() async throws {
        // A regular file where the cache expects its directory: every store fails at
        // createDirectory.
        let blockedBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-cache-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockedBase)
        defer { try? FileManager.default.removeItem(at: blockedBase) }
        let blockedCache = CloudKitBlobCache(baseDir: blockedBase, maxBytes: 100 * 1024 * 1024)

        let chunkData = Data(repeating: 0x11, count: 8 * 1024)
        let stub = StagingChunkStore(chunkData: chunkData, stagingDir: stagingDir)
        let cachedStore = CachedChunkedBlobStore(store: stub,
                                                 cache: blockedCache,
                                                 albumID: "album-1",
                                                 validationTag: "tag-v1")

        let fetched = try await cachedStore.fetchChunk(mediaRecordName: "media-1", index: 0)
        XCTAssertEqual(fetched, chunkData, "a failed cache store must not break the fetch")

        let staged = try XCTUnwrap(stub.staged.first)
        let cleanedUp = await Self.waitUntil {
            !FileManager.default.fileExists(atPath: staged.url.path)
        }
        XCTAssertTrue(cleanedUp, "a rejected cache store must still reclaim the staged file")
    }

    // MARK: - Helpers

    private func waitForCachedURL(recordName: String, changeTag: String?) async throws -> URL {
        var found: URL?
        _ = await Self.waitUntil { [cache] in
            found = await cache?.cachedURL(recordName: recordName, changeTag: changeTag)
            return found != nil
        }
        return try XCTUnwrap(found, "the chunk never landed in the cache")
    }

    private static func waitUntil(timeout: TimeInterval = 5,
                                  _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// (device, inode) — equal only for the same file on disk. `copyItem` allocates a
    /// new inode even when APFS clones the extents, so this distinguishes a move from
    /// any form of re-write.
    fileprivate static func fileIdentity(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}

// MARK: - Stub

private actor FetchCounter {
    var count = 0
    func increment() { count += 1 }
}

private final class StubChunkStore: ChunkedBlobStoring, Sendable {
    let chunkData: Data
    let fetches = FetchCounter()

    init(chunkData: Data) {
        self.chunkData = chunkData
    }

    @discardableResult
    func uploadChunks(enc3FileURL: URL, mediaRecordName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
        fatalError("not used in this test")
    }

    func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
        await fetches.increment()
        return chunkData
    }

    func delete(mediaRecordName: String, chunkCount: Int) async throws {
        fatalError("not used in this test")
    }
}


/// Stages every fetched chunk in a file it hands over, the way
/// `CloudKitChunkedBlobStore` hands over the adapter's CKAsset snapshot.
private final class StagingChunkStore: ChunkedBlobStoring, @unchecked Sendable {
    struct Staged {
        let url: URL
        let identity: String?
    }

    let chunkData: Data
    let stagingDir: URL
    private let lock = NSLock()
    private var _staged: [Staged] = []
    private var _fetchCount = 0

    var staged: [Staged] { lock.withLock { _staged } }
    var fetchCount: Int { lock.withLock { _fetchCount } }

    init(chunkData: Data, stagingDir: URL) {
        self.chunkData = chunkData
        self.stagingDir = stagingDir
    }

    @discardableResult
    func uploadChunks(enc3FileURL: URL, mediaRecordName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
        fatalError("not used in this test")
    }

    func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
        try await fetchChunkStaged(mediaRecordName: mediaRecordName, index: index).data
    }

    func fetchChunkStaged(mediaRecordName: String, index: Int) async throws -> FetchedChunk {
        let url = stagingDir.appendingPathComponent("staged-\(UUID().uuidString).bin")
        try chunkData.write(to: url)
        lock.withLock {
            _fetchCount += 1
            _staged.append(Staged(url: url, identity: CachedChunkedBlobStoreTests.fileIdentity(url)))
        }
        return FetchedChunk(data: chunkData, stagedFileURL: url)
    }

    func delete(mediaRecordName: String, chunkCount: Int) async throws {
        fatalError("not used in this test")
    }
}
