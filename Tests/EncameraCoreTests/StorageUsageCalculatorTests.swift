//
//  StorageUsageCalculatorTests.swift
//  EncameraCoreTests
//
//  The disk walk behind the Storage Insights screen, over a temp-directory fixture.
//

import XCTest
@testable import EncameraCore

final class StorageUsageCalculatorTests: XCTestCase {

    private var tempRoot: URL!
    private var createdAlbumDirectories: [URL] = []

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-calc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        for directory in createdAlbumDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdAlbumDirectories = []
    }

    // MARK: - Builders

    private func makeAlbumManager() -> MockAlbumManager {
        MockAlbumManager(keyManager: DemoKeyManager())
    }

    private func makeAlbum(_ storage: StorageType) -> Album {
        let key = PrivateKey(name: "key", keyBytes: Array(repeating: 4, count: 32), creationDate: Date())
        return Album(name: "Calc-\(UUID().uuidString)", storageOption: storage, creationDate: Date(), key: key)
    }

    /// Materializes a `.local` album's real directory (the calculator reads
    /// `album.storageURL`, not a fixture path) and fills it with `bytes`.
    private func seedLocalAlbum(_ album: Album, bytes: Int) throws {
        let directory = album.storageURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdAlbumDirectories.append(directory)
        try Data(repeating: 0xEE, count: bytes).write(to: directory.appendingPathComponent("media.encimage"))
    }

    private func seedDirectory(_ name: String, bytes: Int) throws -> URL {
        let directory = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: bytes).write(to: directory.appendingPathComponent("file"))
        return directory
    }

    private func sidecarFile() -> URL {
        tempRoot.appendingPathComponent("\(UUID().uuidString).encsizes")
    }

    /// Allocated size, the measure the calculator reports — computed here
    /// independently so a test never grades the walk against its own arithmetic.
    /// - Parameter excluding: filenames the measured figure deliberately omits — the
    ///   blob cache's own `.cacheindex.json` is bookkeeping, not cached media.
    private func allocatedBytes(of directory: URL, excluding: Set<String> = []) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, !excluding.contains(url.lastPathComponent) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func makeCalculator(albumManager: MockAlbumManager,
                                cacheDir: URL,
                                thumbnails: URL,
                                indexes: URL,
                                sidecars: [String: AlbumSizeSidecar] = [:]) -> StorageUsageCalculator {
        StorageUsageCalculator(
            albumManager: albumManager,
            cache: CloudKitBlobCache(baseDir: cacheDir, maxBytes: 500 * 1024 * 1024),
            backfill: AlbumSizeBackfill(makeStore: { _ in MockCloudKitMediaStore() }),
            thumbnailDirectory: thumbnails,
            indexDirectory: indexes,
            makeSidecar: { album in sidecars[album.id] ?? AlbumSizeSidecar(fileURL: URL(fileURLWithPath: "/dev/null/missing")) }
        )
    }

    // MARK: - Tests

    func testBreakdownSumsEveryBucketFromDisk() async throws {
        let albumManager = makeAlbumManager()
        let local = makeAlbum(.local)
        try seedLocalAlbum(local, bytes: 4_000)
        albumManager.albumsOnDisk = [local]

        let cacheDir = tempRoot.appendingPathComponent("cache", isDirectory: true)
        let cache = CloudKitBlobCache(baseDir: cacheDir, maxBytes: 500 * 1024 * 1024)
        let source = tempRoot.appendingPathComponent("blob")
        try Data(repeating: 0xAA, count: 2_000).write(to: source)
        _ = try await cache.store(recordName: "r1", changeTag: nil, albumID: "album", from: source)

        let thumbnails = try seedDirectory("thumbs", bytes: 500)
        let indexes = try seedDirectory("indexes", bytes: 300)

        let calculator = StorageUsageCalculator(
            albumManager: albumManager,
            cache: cache,
            backfill: AlbumSizeBackfill(makeStore: { _ in MockCloudKitMediaStore() }),
            thumbnailDirectory: thumbnails,
            indexDirectory: indexes,
            makeSidecar: { _ in AlbumSizeSidecar(fileURL: self.sidecarFile()) }
        )

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(breakdown.localMediaBytes, try allocatedBytes(of: local.storageURL))
        XCTAssertEqual(breakdown.cachedCloudBytes,
                       try allocatedBytes(of: cacheDir, excluding: [".cacheindex.json"]))
        XCTAssertEqual(breakdown.thumbnailBytes, try allocatedBytes(of: thumbnails))
        XCTAssertEqual(breakdown.indexBytes, try allocatedBytes(of: indexes))
        XCTAssertEqual(breakdown.totalDeviceBytes,
                       breakdown.localMediaBytes + breakdown.cachedCloudBytes
                       + breakdown.thumbnailBytes + breakdown.indexBytes)
    }

    /// The regression guard for the most likely silent under-report.
    func testHiddenAlbumsAreIncludedInTheTotal() async throws {
        let albumManager = makeAlbumManager()
        let visible = makeAlbum(.local)
        let hidden = makeAlbum(.local)
        try seedLocalAlbum(visible, bytes: 1_000)
        try seedLocalAlbum(hidden, bytes: 1_000)
        albumManager.albumsOnDisk = [visible]
        albumManager.hiddenAlbumsOnDisk = [hidden]

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("no-thumbs"),
                                        indexes: tempRoot.appendingPathComponent("no-indexes"))

        let breakdown = try await calculator.breakdown()

        let expected = try allocatedBytes(of: visible.storageURL) + allocatedBytes(of: hidden.storageURL)
        XCTAssertEqual(breakdown.localMediaBytes, expected, "A hidden album's bytes still occupy the disk")
        XCTAssertEqual(albumManager.fetchIncludingHiddenCalls, [true])
    }

    func testMissingDirectoriesContributeZero() async throws {
        let albumManager = makeAlbumManager()
        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("never-created"),
                                        thumbnails: tempRoot.appendingPathComponent("never-created-2"),
                                        indexes: tempRoot.appendingPathComponent("never-created-3"))

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(breakdown.totalDeviceBytes, 0)
        XCTAssertTrue(breakdown.isEmpty)
    }

    func testCancellationStopsTheWalkAndThrows() async throws {
        let albumManager = makeAlbumManager()
        // Enough albums that the per-album cancellation check is reached before the
        // walk finishes.
        for _ in 0..<200 {
            let album = makeAlbum(.local)
            try seedLocalAlbum(album, bytes: 128)
            albumManager.albumsOnDisk.append(album)
        }
        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"))

        let task = Task { try await calculator.breakdown() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled walk must throw rather than return a partial breakdown")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCalculatorDoesNotRunOnTheMainActor() async throws {
        let albumManager = makeAlbumManager()
        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"))

        _ = try await MainActor.run { Task { try await calculator.breakdown() } }.value

        let onMain = await calculator._testRanOnMainThread()
        XCTAssertFalse(onMain, "The disk walk must not block the UI, even when called from the main actor")
    }

    /// ENC-162's invariant, over a real disk walk rather than a constructed value.
    func testReclaimableExcludesLocalMediaEndToEnd() async throws {
        let albumManager = makeAlbumManager()
        let local = makeAlbum(.local)
        try seedLocalAlbum(local, bytes: 8_000)
        albumManager.albumsOnDisk = [local]

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"))

        let breakdown = try await calculator.breakdown()

        XCTAssertGreaterThan(breakdown.localMediaBytes, 0)
        XCTAssertEqual(breakdown.reclaimableBytes, 0, "Local media is never offered up for reclaim")
    }

    func testCloudBytesSumPerAlbumSidecars() async throws {
        let albumManager = makeAlbumManager()
        let first = makeAlbum(.cloudKit)
        let second = makeAlbum(.cloudKit)
        albumManager.albumsOnDisk = [first, second]

        let firstSidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await firstSidecar.replace(with: ["a#0": 1_000], markBackfilled: true)
        let secondSidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await secondSidecar.replace(with: ["b#0": 250], markBackfilled: true)

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"),
                                        sidecars: [first.id: firstSidecar, second.id: secondSidecar])

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(breakdown.cloudBytes, 1_250)
        XCTAssertEqual(breakdown.totalDeviceBytes, 0, "Cloud bytes are not on this device")
    }

    /// Legacy iCloud Drive albums are excluded from every bucket, but counted, so the
    /// screen can say why the total looks small instead of silently under-reporting.
    func testLegacyICloudDriveAlbumsAreCountedButNotMeasured() async throws {
        let albumManager = makeAlbumManager()
        albumManager.albumsOnDisk = [makeAlbum(.icloud), makeAlbum(.icloud)]

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"))

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(breakdown.legacyICloudDriveAlbumCount, 2)
        XCTAssertEqual(breakdown.totalDeviceBytes, 0)
    }
}
