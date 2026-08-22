//
//  AlbumSizeSidecarTests.swift
//  EncameraCoreTests
//
//  The per-album size sidecar and the sync paths that fill it, driven through the
//  `CloudKitMediaStoring` fake — never a live container.
//

import XCTest
@testable import EncameraCore

final class AlbumSizeSidecarTests: XCTestCase {

    private var tempRoot: URL!
    private var deleteQueueSuites: [String] = []

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        for suite in deleteQueueSuites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        deleteQueueSuites = []
    }

    // MARK: - Builders

    private func sidecarURL() -> URL {
        tempRoot.appendingPathComponent("\(UUID().uuidString).encsizes")
    }

    private func makeDeleteQueue() -> CloudKitMediaDeleteQueue {
        let suite = "sidecar-delete-\(UUID().uuidString)"
        deleteQueueSuites.append(suite)
        return CloudKitMediaDeleteQueue(defaults: UserDefaults(suiteName: suite)!)
    }

    private func makeCoordinator(store: MockCloudKitMediaStore,
                                 sidecar: AlbumSizeSidecar) -> CloudKitSyncCoordinator {
        let index = MediaIndexStore(keyBytes: Array(repeating: 7, count: 32),
                                    indexURL: tempRoot.appendingPathComponent("\(UUID().uuidString).encindex"))
        let cache = CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache-\(UUID().uuidString)"),
                                      maxBytes: 500 * 1024 * 1024)
        return CloudKitSyncCoordinator(albumID: "a1",
                                       store: store,
                                       cache: cache,
                                       indexStore: index,
                                       sizeSidecar: sidecar,
                                       bus: FileOperationBus(),
                                       deleteQueue: makeDeleteQueue())
    }

    private func meta(recordName: String,
                      mediaID: String,
                      type: MediaType,
                      sizeBytes: Int64) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: recordName,
                              albumID: "a1",
                              mediaID: mediaID,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: sizeBytes,
                              creationDeviceID: "device",
                              schemaVersion: 1,
                              recordChangeTag: "tag-\(recordName)")
    }

    // MARK: - Tests

    /// The headline correctness test: a Live Photo is two CloudKit records that
    /// collapse into one index entry, and both components' bytes must survive that
    /// collapse. Keying by `mediaID` would report only one of these sizes.
    func testLivePhotoComponentsBothCountTowardTotal() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [
                meta(recordName: "live#0", mediaID: "live", type: .photo, sizeBytes: 700),
                meta(recordName: "live#1", mediaID: "live", type: .video, sizeBytes: 3_300),
            ],
            deleted: [], token: nil, moreComing: false
        )
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let coord = makeCoordinator(store: store, sidecar: sidecar)

        try await coord.sync(albumID: "a1")

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 4_000, "Both Live Photo components must contribute their own size")
        let count = await sidecar.recordCount()
        XCTAssertEqual(count, 2, "Sizes are keyed by record name, so two records mean two keys")
    }

    func testDeltaSyncPersistsSizesFromMetadata() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [
                meta(recordName: "m1#0", mediaID: "m1", type: .photo, sizeBytes: 111),
                meta(recordName: "m2#0", mediaID: "m2", type: .photo, sizeBytes: 222),
            ],
            deleted: [], token: nil, moreComing: false
        )
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let coord = makeCoordinator(store: store, sidecar: sidecar)

        try await coord.sync(albumID: "a1")

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 333)
    }

    func testRemovedRecordStopsCountingTowardTotal() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [
                meta(recordName: "live#0", mediaID: "live", type: .photo, sizeBytes: 700),
                meta(recordName: "live#1", mediaID: "live", type: .video, sizeBytes: 3_300),
            ],
            deleted: [], token: nil, moreComing: false
        )
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let coord = makeCoordinator(store: store, sidecar: sidecar)
        try await coord.sync(albumID: "a1")

        try await coord.remove(recordName: "live#1", albumID: "a1")
        var total = await sidecar.totalBytes()
        XCTAssertEqual(total, 700, "Removing the video component drops only the video's bytes")

        try await coord.remove(recordName: "live#0", albumID: "a1")
        total = await sidecar.totalBytes()
        XCTAssertEqual(total, 0)
    }

    func testUploadRecordsItsSizeInTheSidecar() async throws {
        let store = MockCloudKitMediaStore()
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let coord = makeCoordinator(store: store, sidecar: sidecar)
        let blob = tempRoot.appendingPathComponent("m1.blob")
        try Data(repeating: 9, count: 64).write(to: blob)

        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1_234,
                                         encryptedFileURL: blob, encryptedThumbURL: nil,
                                         recordName: "m1#0")
        _ = try await coord.upload(upload, progress: { _ in })

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 1_234)
    }

    func testSidecarSurvivesRelaunch() async throws {
        let url = sidecarURL()
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [meta(recordName: "m1#0", mediaID: "m1", type: .photo, sizeBytes: 4_096)],
            deleted: [], token: nil, moreComing: false
        )
        let coord = makeCoordinator(store: store, sidecar: AlbumSizeSidecar(fileURL: url))
        try await coord.sync(albumID: "a1")

        let relaunched = AlbumSizeSidecar(fileURL: url)
        let total = await relaunched.totalBytes()
        XCTAssertEqual(total, 4_096)
        let existed = await relaunched.existsOnDisk()
        XCTAssertTrue(existed)
    }

    /// The sidecar answers a Settings screen. Failing to write it must never fail a
    /// sync or hold back the change-token commit.
    func testSidecarWriteFailureDoesNotFailSync() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [meta(recordName: "m1#0", mediaID: "m1", type: .photo, sizeBytes: 10)],
            deleted: [], token: nil, moreComing: false
        )
        // A path whose parent is a regular file: `createDirectory` cannot make it, so
        // every write throws.
        let blocker = tempRoot.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let sidecar = AlbumSizeSidecar(fileURL: blocker.appendingPathComponent("a.encsizes"))
        let coord = makeCoordinator(store: store, sidecar: sidecar)

        try await coord.sync(albumID: "a1")

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 0, "Nothing persisted, but the sync itself succeeded")
        XCTAssertEqual(store.committedTokenCount, 1, "The change token still commits after a sidecar failure")
    }

    /// The privacy guard: the file is named by a hash and holds record names and
    /// integers only.
    func testSidecarContainsNoCleartextAlbumName() async throws {
        let key = PrivateKey(name: "key", keyBytes: Array(repeating: 3, count: 32), creationDate: Date())
        let album = Album(name: "Beach Trip 2026", storageOption: .cloudKit, creationDate: Date(), key: key)
        let url = AlbumSizeSidecar.sidecarURL(for: album)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let sidecar = AlbumSizeSidecar(album: album)
        try await sidecar.apply(updates: ["m1#0": 42])

        XCTAssertFalse(url.lastPathComponent.contains("Beach"),
                       "The filename is a hash of the album id, not its name")
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "Beach Trip"),
                     "No cleartext album name may reach the sidecar")
    }

    func testApplyMergesRatherThanReplacingUnseenRecords() async throws {
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        try await sidecar.apply(updates: ["m1#0": 100, "m2#0": 200])
        try await sidecar.apply(updates: ["m2#0": 250])

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 350, "A delta that mentions one record must not zero the others")
    }
}
