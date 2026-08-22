//
//  AlbumSizeBackfillTests.swift
//  EncameraCoreTests
//
//  The one-shot backfill for albums that synced before the size sidecar existed.
//

import XCTest
@testable import EncameraCore

final class AlbumSizeBackfillTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Builders

    private func makeAlbum(storage: StorageType = .cloudKit) -> Album {
        let key = PrivateKey(name: "key", keyBytes: Array(repeating: 5, count: 32), creationDate: Date())
        return Album(name: "Backfill-\(UUID().uuidString)", storageOption: storage, creationDate: Date(), key: key)
    }

    private func albumIDHash(_ album: Album) -> String {
        SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) ?? album.id
    }

    private func makeIndex(entries: [MediaIndexEntry]) async throws -> MediaIndexStore {
        let store = MediaIndexStore(keyBytes: Array(repeating: 7, count: 32),
                                    indexURL: tempRoot.appendingPathComponent("\(UUID().uuidString).encindex"))
        try await store.replace(with: entries)
        return store
    }

    private func entry(id: String, video: Bool = false) -> MediaIndexEntry {
        MediaIndexEntry(id: id,
                        hasPhotoComponent: true,
                        hasVideoComponent: video,
                        dateEncrypted: Date(timeIntervalSince1970: 10),
                        dateTaken: nil,
                        subtypeRawValue: 0)
    }

    private func meta(_ recordName: String, albumID: String, sizeBytes: Int64,
                      type: MediaType = .photo) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: recordName,
                              albumID: albumID,
                              mediaID: MediaRecordName.mediaID(from: recordName),
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: sizeBytes,
                              creationDeviceID: "device",
                              schemaVersion: 1,
                              recordChangeTag: "tag")
    }

    private func sidecar() -> AlbumSizeSidecar {
        AlbumSizeSidecar(fileURL: tempRoot.appendingPathComponent("\(UUID().uuidString).encsizes"))
    }

    // MARK: - Tests

    func testBackfillPopulatesSizesForPreexistingAlbum() async throws {
        let album = makeAlbum()
        let hash = albumIDHash(album)
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = [
            meta("m1#0", albumID: hash, sizeBytes: 1_000),
            meta("m2#0", albumID: hash, sizeBytes: 2_500),
        ]
        let side = sidecar()
        let index = try await makeIndex(entries: [entry(id: "m1"), entry(id: "m2")])

        let bytes = try await AlbumSizeBackfill()
            .cloudBytes(for: album, store: store, sidecar: side, indexStore: index)

        XCTAssertEqual(bytes, 3_500)
        let total = await side.totalBytes()
        XCTAssertEqual(total, 3_500, "The figure is persisted, not just returned")
    }

    func testBackfillIsIdempotent() async throws {
        let album = makeAlbum()
        let hash = albumIDHash(album)
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = [meta("m1#0", albumID: hash, sizeBytes: 640)]
        let side = sidecar()
        let index = try await makeIndex(entries: [entry(id: "m1")])
        let backfill = AlbumSizeBackfill()

        let first = try await backfill.cloudBytes(for: album, store: store, sidecar: side, indexStore: index)
        let second = try await backfill.cloudBytes(for: album, store: store, sidecar: side, indexStore: index)

        XCTAssertEqual(first, 640)
        XCTAssertEqual(second, 640)
        XCTAssertEqual(store.fetchMetadataCalls.count, 1, "The second run must not hit the store again")
    }

    /// Invariant 3: the lazy blob asset is never requested for a metadata read.
    func testBackfillNeverRequestsTheBlobAsset() async throws {
        let album = makeAlbum()
        let hash = albumIDHash(album)
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = [meta("m1#0", albumID: hash, sizeBytes: 10)]
        let index = try await makeIndex(entries: [entry(id: "m1")])

        _ = try await AlbumSizeBackfill()
            .cloudBytes(for: album, store: store, sidecar: sidecar(), indexStore: index)

        XCTAssertEqual(store.fetchBlobCount, 0, "A size backfill must never download a blob")
        XCTAssertEqual(store.fetchMetadataCalls.map(\.includeThumbnail), [false],
                       "Not even the eager thumbnail is worth fetching for a byte count")
    }

    func testBackfillDoesNotResetTheChangeToken() async throws {
        let album = makeAlbum()
        let hash = albumIDHash(album)
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = [meta("m1#0", albumID: hash, sizeBytes: 10)]
        let index = try await makeIndex(entries: [entry(id: "m1")])

        _ = try await AlbumSizeBackfill()
            .cloudBytes(for: album, store: store, sidecar: sidecar(), indexStore: index)

        XCTAssertEqual(store.resetChangeTokenCount, 0)
        XCTAssertEqual(store.committedTokenCount, 0)
        XCTAssertEqual(store.fetchChangesCount, 0, "A backfill is not a resync")
    }

    func testBackfillNoOpsWithoutAnAccount() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.accountAvailableValue = false
        store.metadataToReturn = [meta("m1#0", albumID: albumIDHash(album), sizeBytes: 10)]
        let index = try await makeIndex(entries: [entry(id: "m1")])

        let bytes = try await AlbumSizeBackfill()
            .cloudBytes(for: album, store: store, sidecar: sidecar(), indexStore: index)

        XCTAssertNil(bytes, "Unknown is not zero — an account-less device must not claim the album is empty")
        XCTAssertTrue(store.fetchMetadataCalls.isEmpty)
    }

    func testBackfillSkipsLocalAlbums() async throws {
        let album = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let index = try await makeIndex(entries: [entry(id: "m1")])

        let bytes = try await AlbumSizeBackfill()
            .cloudBytes(for: album, store: store, sidecar: sidecar(), indexStore: index)

        XCTAssertNil(bytes)
        XCTAssertTrue(store.fetchMetadataCalls.isEmpty, "A local album has no CloudKit records to measure")
    }

    func testCancelledBackfillDoesNotReportAPartialTotalAsComplete() async throws {
        let album = makeAlbum()
        let hash = albumIDHash(album)
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = [meta("m1#0", albumID: hash, sizeBytes: 999)]
        store.fetchMetadataDelayNanos = 2_000_000_000
        let side = sidecar()
        let index = try await makeIndex(entries: [entry(id: "m1")])
        let backfill = AlbumSizeBackfill()

        let task = Task {
            try await backfill.cloudBytes(for: album, store: store, sidecar: side, indexStore: index)
        }
        // Let the fetch get underway before pulling the rug out.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled backfill must throw rather than return a total")
        } catch is CancellationError {
            // Expected.
        }

        let backfilled = await side.isBackfilled()
        XCTAssertFalse(backfilled, "The album must still be marked as needing a backfill")
        let existed = await side.existsOnDisk()
        XCTAssertFalse(existed, "Nothing partial may be written")
    }

    func testLivePhotoComponentsAreBothBackfilled() async throws {
        let album = makeAlbum()
        let hash = albumIDHash(album)
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = [
            meta("live#0", albumID: hash, sizeBytes: 700, type: .photo),
            meta("live#1", albumID: hash, sizeBytes: 3_300, type: .video),
        ]
        let index = try await makeIndex(entries: [entry(id: "live", video: true)])

        let bytes = try await AlbumSizeBackfill()
            .cloudBytes(for: album, store: store, sidecar: sidecar(), indexStore: index)

        XCTAssertEqual(bytes, 4_000)
    }

    /// The zone is shared across albums, so another album's records must not inflate
    /// this one's total.
    func testBackfillIgnoresRecordsFromOtherAlbums() async throws {
        let album = makeAlbum()
        let hash = albumIDHash(album)
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = [
            meta("m1#0", albumID: hash, sizeBytes: 100),
            meta("other#0", albumID: "some-other-album", sizeBytes: 5_000),
        ]
        let index = try await makeIndex(entries: [entry(id: "m1")])

        let bytes = try await AlbumSizeBackfill()
            .cloudBytes(for: album, store: store, sidecar: sidecar(), indexStore: index)

        XCTAssertEqual(bytes, 100)
    }
}
