//
//  ChunkedBlobStoreTests.swift
//  EncameraCoreTests
//
//  Covers `CloudKitChunkedBlobStore` against `FakeAssetDatabase` — the real
//  store class, the real record construction, the real header parsing, with only
//  the CKDatabase swapped out.
//
//  Everything here previously needed the rig. It does not: what the device suite
//  uniquely proves is CKAsset *delivery* — latency, throttling, asset semantics —
//  not whether the store names records correctly, batches within CloudKit's
//  limits, or round-trips bytes. Those are decisions in our code and belong in a
//  test that runs in a second.
//

import XCTest
import CloudKit
@testable import EncameraCore

final class ChunkedBlobStoreTests: XCTestCase {

    private let key = [UInt8](repeating: 0x33, count: 32)
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var mock: FakeAssetDatabase!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunkstore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = makeIsolatedDefaults()
        mock = FakeAssetDatabase()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    private func makeStore(account: CKAccountStatus = .available,
                           zoneProvisioner: RecordZoneProvisioning? = nil) -> CloudKitChunkedBlobStore {
        let container = CloudKitContainer(accountStatusProvider: StubAccountStatusProvider(status: account),
                                          zoneProvisioner: StubZoneProvisioner(),
                                          defaults: defaults)
        return CloudKitChunkedBlobStore(container: container,
                                        adapter: mock,
                                        zoneProvisioner: zoneProvisioner ?? StubZoneProvisioner(),
                                        defaults: defaults)
    }

    private func fixture(bytes count: Int) -> Data {
        var data = Data(capacity: count)
        var state: UInt64 = 0xDEADBEEFCAFEBABE
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    /// Writes an ENC3 blob and returns (file, header, plaintext).
    @discardableResult
    private func makeBlob(bytes: Int, chunkSize: Int) throws -> (url: URL, header: SeekableEncryptedHeader, plaintext: Data) {
        let plaintext = fixture(bytes: bytes)
        let source = tempDir.appendingPathComponent("src-\(UUID().uuidString).bin")
        try plaintext.write(to: source)
        let enc3 = tempDir.appendingPathComponent("blob-\(UUID().uuidString).enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: chunkSize)
            .encrypt(source: source, destination: enc3)
        return (enc3, header, plaintext)
    }

    private var savedRecords: [CKRecord] { mock.savedRecordBatches.flatMap { $0 } }

    // MARK: - Upload shape

    func testUploadWritesOneRecordPerChunk() async throws {
        let blob = try makeBlob(bytes: 10_000, chunkSize: 1_000)
        XCTAssertEqual(blob.header.chunkCount, 10)

        try await makeStore().uploadChunks(enc3FileURL: blob.url, mediaRecordName: "media-1", progress: { _ in })

        let chunks = savedRecords.filter { $0.recordType == ChunkedBlobSchema.Chunk.recordType }
        XCTAssertEqual(chunks.count, 10)
        XCTAssertEqual(savedRecords.count, 10, "the chunk records are the only records the store writes")
    }

    func testChunkRecordNamesAreTheComputedOnes() async throws {
        let blob = try makeBlob(bytes: 3_000, chunkSize: 1_000)
        try await makeStore().uploadChunks(enc3FileURL: blob.url, mediaRecordName: "abc", progress: { _ in })

        let names = Set(savedRecords.map(\.recordID.recordName))
        XCTAssertEqual(names, ["abc#c0", "abc#c1", "abc#c2"],
                       "names must be computable so reads are fetch-by-ID, never a query")
    }

    func testChunkRecordsLandInTheBlobZoneNotTheIndexZone() async throws {
        let blob = try makeBlob(bytes: 2_000, chunkSize: 1_000)
        try await makeStore().uploadChunks(enc3FileURL: blob.url, mediaRecordName: "abc", progress: { _ in })

        // The whole reason chunks are separated: they must never enter the index
        // zone's change feed, which every device walks on every delta sync.
        for record in savedRecords {
            XCTAssertEqual(record.recordID.zoneID.zoneName, ChunkedBlobSchema.zoneName)
            XCTAssertNotEqual(record.recordID.zoneID.zoneName, CloudKitSchema.zoneName)
        }
    }

    func testUploadBatchesStayWithinCloudKitsRequestLimit() async throws {
        // 120 chunks: CloudKit documents a 200-record / 200-asset-token ceiling per
        // request, and one asset per chunk record keeps those aligned.
        let blob = try makeBlob(bytes: 120_000, chunkSize: 1_000)
        XCTAssertEqual(blob.header.chunkCount, 120)

        try await makeStore().uploadChunks(enc3FileURL: blob.url, mediaRecordName: "abc", progress: { _ in })

        XCTAssertGreaterThan(mock.savedRecordBatches.count, 1, "120 chunks must not go in one request")
        for batch in mock.savedRecordBatches {
            XCTAssertLessThanOrEqual(batch.count, 200, "batch exceeds CloudKit's per-request ceiling")
        }
    }

    func testChunkAssetSizesMatchTheGeometry() async throws {
        let blob = try makeBlob(bytes: 2_500, chunkSize: 1_000)
        try await makeStore().uploadChunks(enc3FileURL: blob.url, mediaRecordName: "abc", progress: { _ in })

        // `allRecords`, not `savedRecords`: the store deletes its scratch directory
        // once the save returns (correct — CloudKit reads the bytes during the save),
        // so only the double's persisted copies still have readable assets.
        let chunks = mock.allRecords
            .filter { $0.recordType == ChunkedBlobSchema.Chunk.recordType }
            .sorted { ($0[ChunkedBlobSchema.Chunk.chunkIndex] as? Int64 ?? 0) < ($1[ChunkedBlobSchema.Chunk.chunkIndex] as? Int64 ?? 0) }

        for (index, record) in chunks.enumerated() {
            let asset = try XCTUnwrap(record[ChunkedBlobSchema.Chunk.encChunk] as? CKAsset)
            let url = try XCTUnwrap(asset.fileURL)
            let size = try Data(contentsOf: url).count
            XCTAssertEqual(size, blob.header.geometry.ciphertextSize(ofChunk: index),
                           "chunk \(index) asset is the wrong size")
        }
    }

    /// The bar stays short of 100% until the caller's own commit record lands, so
    /// a chunk upload that finishes is not reported as a finished save.
    func testUploadReportsBoundedProgressThatStopsShortOfComplete() async throws {
        let blob = try makeBlob(bytes: 5_000, chunkSize: 1_000)
        let collector = ProgressCollector()
        try await makeStore().uploadChunks(enc3FileURL: blob.url,
                                           mediaRecordName: "abc",
                                           progress: { collector.record($0) })
        let reported = collector.values
        XCTAssertFalse(reported.isEmpty)
        XCTAssertTrue(reported.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(try XCTUnwrap(reported.last), 5.0 / 6.0, accuracy: 0.0001)
    }

    func testUploadRefusesWhenTheAccountIsUnavailable() async throws {
        let blob = try makeBlob(bytes: 1_000, chunkSize: 1_000)
        let store = makeStore(account: .noAccount)
        await XCTAssertThrowsErrorAsync(
            try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "abc", progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? ChunkedBlobError, .accountUnavailable)
        }
        XCTAssertTrue(mock.savedRecordBatches.isEmpty, "nothing may be written without an account")
    }

    // MARK: - Fetch

    /// The end-to-end claim, minus CKAsset delivery: upload a blob through the real
    /// store, read it back through the real store, decrypt it, and get the original
    /// bytes. This is the test that removes the rig from the iteration loop.
    func testUploadThenStreamBackReproducesTheOriginalBytes() async throws {
        let blob = try makeBlob(bytes: 30_000, chunkSize: 4_096)
        let store = makeStore()
        let header = try await store.uploadChunks(enc3FileURL: blob.url,
                                                  mediaRecordName: "media-1",
                                                  progress: { _ in })

        // Feed everything the upload wrote back as the database's contents, which is
        // what a fetch-by-ID would find on the server.

        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)
        XCTAssertEqual(session.plaintextLength, 30_000)
        let streamed = try await session.reader.plaintext(range: 0..<30_000)
        XCTAssertEqual(streamed, blob.plaintext)
    }

    func testSeekThroughTheRealStoreFetchesOnlyTheOverlappingChunk() async throws {
        let blob = try makeBlob(bytes: 100_000, chunkSize: 10_000)
        let store = makeStore()
        let header = try await store.uploadChunks(enc3FileURL: blob.url,
                                                  mediaRecordName: "media-1",
                                                  progress: { _ in })
        let fetchesAfterUpload = mock.fetchCount

        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)
        let got = try await session.reader.plaintext(range: 50_000..<50_100)
        XCTAssertEqual(got, blob.plaintext.subdata(in: 50_000..<50_100))

        // One fetch, for chunk 5. Nothing else — the header came with the commit
        // record, so opening the session costs no round trip.
        XCTAssertEqual(mock.fetchCount - fetchesAfterUpload, 1)
        let telemetry = await session.telemetry()
        XCTAssertEqual(telemetry.fetchOrder, [5])
    }

    func testFetchChunkAsksForOnlyTheAssetKeyAtTopQoS() async throws {
        let blob = try makeBlob(bytes: 2_000, chunkSize: 1_000)
        let store = makeStore()
        try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "m", progress: { _ in })

        _ = try await store.fetchChunk(mediaRecordName: "m", index: 1)

        // `desiredKeys` keeps the transfer to the one asset; `.userInteractive` is a
        // real throughput knob for asset transfers, and the default `.utility` opts
        // into discretionary networking.
        XCTAssertEqual(mock.lastFetchDesiredKeys, [ChunkedBlobSchema.Chunk.encChunk])
        XCTAssertEqual(mock.lastFetchQualityOfService, .userInteractive)
    }

    func testFetchChunkReportsAMissingChunkDistinctly() async throws {
        await XCTAssertThrowsErrorAsync(
            try await makeStore().fetchChunk(mediaRecordName: "m", index: 3)
        ) { error in
            XCTAssertEqual(error as? ChunkedBlobError, .chunkNotFound("m#c3"))
        }
    }

    func testFetchChunkReportsAnAssetlessRecordDistinctly() async throws {
        let recordID = CKRecord.ID(recordName: ChunkedBlobSchema.chunkRecordName(mediaRecordName: "m", index: 0),
                                   zoneID: CKRecordZone.ID(zoneName: ChunkedBlobSchema.zoneName))
        let record = CKRecord(recordType: ChunkedBlobSchema.Chunk.recordType, recordID: recordID)
        _ = try await mock.save(records: [record], savePolicy: .allKeys, perRecordProgress: { _, _ in })

        await XCTAssertThrowsErrorAsync(
            try await makeStore().fetchChunk(mediaRecordName: "m", index: 0)
        ) { error in
            XCTAssertEqual(error as? ChunkedBlobError, .chunkAssetMissing("m#c0"))
        }
    }

    // MARK: - Delete

    func testDeleteRemovesEveryChunkAndNothingElse() async throws {
        try await makeStore().delete(mediaRecordName: "m", chunkCount: 3)

        let deleted = Set(mock.deletedRecordIDBatches.flatMap { $0 }.map(\.recordName))
        XCTAssertEqual(deleted, ["m#c0", "m#c1", "m#c2"])
    }

    func testDeleteBatchesLargeChunkCounts() async throws {
        try await makeStore().delete(mediaRecordName: "m", chunkCount: 300)
        XCTAssertGreaterThan(mock.deletedRecordIDBatches.count, 1)
        for batch in mock.deletedRecordIDBatches {
            XCTAssertLessThanOrEqual(batch.count, 200)
        }
    }

    // MARK: - Blob zone latch

    /// Refuses every record save until the zone has been provisioned, the way
    /// CloudKit answers a write into a zone that does not exist.
    private final class ZoneGatedProvisioner: RecordZoneProvisioning {
        private let database: FakeAssetDatabase
        private let missingZoneError: Error
        private(set) var savedZoneIDs: [CKRecordZone.ID] = []

        /// `missingZoneError` is how CloudKit answers the write. A record save
        /// reports the missing zone per item inside a partial failure, while other
        /// operations report it at the top level; both must be recognised.
        init(database: FakeAssetDatabase, missingZoneError: Error = CKError(.zoneNotFound)) {
            self.database = database
            self.missingZoneError = missingZoneError
            database.saveError = missingZoneError
        }

        func saveZone(_ zone: CKRecordZone) async throws {
            savedZoneIDs.append(zone.zoneID)
            database.saveError = nil
        }

        func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
            database.saveError = missingZoneError
        }
    }

    /// The shape real CloudKit returned on the rig: an op-level partial failure
    /// carrying the zone error against the record it could not save.
    private func partialZoneNotFound(recordName: String) -> CKError {
        let recordID = CKRecord.ID(recordName: recordName,
                                   zoneID: CKRecordZone.ID(zoneName: ChunkedBlobSchema.zoneName))
        return CKError(.partialFailure,
                       userInfo: [CKPartialErrorsByItemIDKey: [recordID: CKError(.zoneNotFound)]])
    }

    func testUploadCreatesTheBlobZoneWhenItIsMissing() async throws {
        let blob = try makeBlob(bytes: 4_000, chunkSize: 1_000)
        let provisioner = ZoneGatedProvisioner(database: mock)

        try await makeStore(zoneProvisioner: provisioner).uploadChunks(enc3FileURL: blob.url,
                                                                      mediaRecordName: "m",
                                                                      progress: { _ in })

        XCTAssertEqual(provisioner.savedZoneIDs.map(\.zoneName), [ChunkedBlobSchema.zoneName])
        XCTAssertEqual(Set(savedRecords.map(\.recordID.recordName)), ["m#c0", "m#c1", "m#c2", "m#c3"])
        XCTAssertTrue(defaults.bool(forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey))
    }

    func testUploadSkipsZoneCreationWhenTheFlagIsSet() async throws {
        let blob = try makeBlob(bytes: 4_000, chunkSize: 1_000)
        defaults.set(true, forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey)
        let provisioner = StubZoneProvisioner()

        try await makeStore(zoneProvisioner: provisioner).uploadChunks(enc3FileURL: blob.url,
                                                                      mediaRecordName: "m",
                                                                      progress: { _ in })

        XCTAssertTrue(provisioner.savedZoneIDs.isEmpty, "a latched zone must cost no extra round trip")
        XCTAssertEqual(Set(savedRecords.map(\.recordID.recordName)), ["m#c0", "m#c1", "m#c2", "m#c3"])
    }

    func testUploadAfterZoneDeletionRecreatesIt() async throws {
        let blob = try makeBlob(bytes: 4_000, chunkSize: 1_000)
        let provisioner = ZoneGatedProvisioner(database: mock)
        let store = makeStore(zoneProvisioner: provisioner)
        try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "first", progress: { _ in })

        // What the destructive erase does: drop the zone, then clear the latch.
        try await provisioner.deleteZone(CKRecordZone.ID(zoneName: ChunkedBlobSchema.zoneName))
        defaults.removeObject(forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey)
        mock.resetObservations()

        try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "second", progress: { _ in })

        XCTAssertEqual(provisioner.savedZoneIDs.count, 2)
        XCTAssertEqual(Set(savedRecords.map(\.recordID.recordName)),
                       ["second#c0", "second#c1", "second#c2", "second#c3"])
    }

    /// The stale-latch retry. The flag is per-device while the zone is per-account,
    /// so a device that has not seen another device's erase holds a flag it cannot
    /// trust; without the retry it skips the create and fails the same way forever.
    func testUploadRecreatesTheZoneWhenTheLatchIsStale() async throws {
        let blob = try makeBlob(bytes: 4_000, chunkSize: 1_000)
        let provisioner = ZoneGatedProvisioner(database: mock)
        // What another device sharing the account leaves behind: the zone is gone
        // server-side while this device's flag still claims it exists.
        defaults.set(true, forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey)

        try await makeStore(zoneProvisioner: provisioner).uploadChunks(enc3FileURL: blob.url,
                                                                      mediaRecordName: "m",
                                                                      progress: { _ in })

        XCTAssertEqual(provisioner.savedZoneIDs.map(\.zoneName), [ChunkedBlobSchema.zoneName])
        XCTAssertEqual(Set(savedRecords.map(\.recordID.recordName)), ["m#c0", "m#c1", "m#c2", "m#c3"])
    }

    func testUploadRecognisesAStaleLatchInsideAPartialFailure() async throws {
        let blob = try makeBlob(bytes: 4_000, chunkSize: 1_000)
        let provisioner = ZoneGatedProvisioner(database: mock,
                                               missingZoneError: partialZoneNotFound(recordName: "m#c0"))
        defaults.set(true, forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey)

        try await makeStore(zoneProvisioner: provisioner).uploadChunks(enc3FileURL: blob.url,
                                                                      mediaRecordName: "m",
                                                                      progress: { _ in })

        XCTAssertEqual(provisioner.savedZoneIDs.map(\.zoneName), [ChunkedBlobSchema.zoneName])
        XCTAssertEqual(Set(savedRecords.map(\.recordID.recordName)), ["m#c0", "m#c1", "m#c2", "m#c3"])
    }

    // MARK: - Stale zone latch (chunked path)

    /// Device A runs "delete my iCloud data"; device B still has the zone flag
    /// set. The probe fetch returns `.partialFailure` with per-item
    /// `.zoneNotFound` — the shape real CloudKit uses for fetch-by-ID into a
    /// deleted zone. The store must handle this as "zone gone, no existing
    /// chunks", recreate the zone, and complete the upload — not rethrow.
    func testUploadChunksHandlesZoneNotFoundInsidePartialFailure() async throws {
        let blob = try makeBlob(bytes: 3_000, chunkSize: 1_000)
        defaults.set(true, forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey)

        let chunkIDs = (0..<3).map {
            CKRecord.ID(recordName: ChunkedBlobSchema.chunkRecordName(mediaRecordName: "m", index: $0),
                        zoneID: CKRecordZone.ID(zoneName: ChunkedBlobSchema.zoneName))
        }
        let perItem: [AnyHashable: Error] = Dictionary(uniqueKeysWithValues: chunkIDs.map {
            ($0 as AnyHashable, CKError(.zoneNotFound) as Error)
        })
        mock.fetchError = CKError(.partialFailure,
                                   userInfo: [CKPartialErrorsByItemIDKey: perItem])

        XCTAssertTrue(BlobZoneLatch.provesZoneMissing(mock.fetchError!))

        let store = makeStore()
        try await store.uploadChunks(enc3FileURL: blob.url,
                                      mediaRecordName: "m",
                                      progress: { _ in })

        let chunks = savedRecords.filter { $0.recordType == ChunkedBlobSchema.Chunk.recordType }
        XCTAssertEqual(chunks.count, 3,
                       "All chunks must be uploaded after the probe handles zone-not-found")
    }

    // MARK: - Helpers

    /// The `progress` closure is `@Sendable`, so a captured `var` array cannot be
    /// mutated from it. Lock-guarded box instead.
    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []

        func record(_ value: Double) {
            lock.lock(); storage.append(value); lock.unlock()
        }

        var values: [Double] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

}
