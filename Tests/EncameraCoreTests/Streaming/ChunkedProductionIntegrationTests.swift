//
//  ChunkedProductionIntegrationTests.swift
//  EncameraCoreTests
//
//  Regression guards for the ENC3 production integration: the single write rule,
//  the hardened chunk upload (resume-by-probe, save verification, commit-record
//  last), the queue geometry that makes interrupted uploads resumable and
//  deletable, and the read paths that must understand every format ever written.
//

import XCTest
import CloudKit
@testable import EncameraCore

final class ChunkedProductionIntegrationTests: XCTestCase {

    private let key = [UInt8](repeating: 0x44, count: 32)
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var mock: FakeAssetDatabase!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunked-prod-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = makeIsolatedDefaults()
        mock = FakeAssetDatabase()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        // The delete queue is durable and process-wide: an entry left behind would
        // suppress another test's upserts and issue phantom deletes.
        for suite in deleteQueueSuites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        deleteQueueSuites = []
    }

    // MARK: - Fixtures

    private func makeContainer(account: CKAccountStatus = .available) -> CloudKitContainer {
        CloudKitContainer(accountStatusProvider: StubAccountStatusProvider(status: account),
                          zoneProvisioner: StubZoneProvisioner(),
                          defaults: defaults)
    }

    private func makeChunkStore() -> CloudKitChunkedBlobStore {
        CloudKitChunkedBlobStore(container: makeContainer(),
                                 adapter: mock,
                                 zoneProvisioner: StubZoneProvisioner(),
                                 defaults: defaults)
    }

    private func fixture(bytes count: Int) -> Data {
        var data = Data(capacity: count)
        var state: UInt64 = 0x0123456789ABCDEF
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    @discardableResult
    private func makeBlob(bytes: Int, chunkSize: Int, metadata: Data? = nil) throws -> (url: URL, header: SeekableEncryptedHeader, plaintext: Data) {
        let plaintext = fixture(bytes: bytes)
        let source = tempDir.appendingPathComponent("src-\(UUID().uuidString).bin")
        try plaintext.write(to: source)
        let enc3 = tempDir.appendingPathComponent("blob-\(UUID().uuidString).enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: chunkSize)
            .encrypt(source: source, destination: enc3, metadata: metadata)
        return (enc3, header, plaintext)
    }

    private var savedRecords: [CKRecord] { mock.savedRecordBatches.flatMap { $0 } }

    /// The video component's record name, computed the way the product computes
    /// it — the type suffix is `MediaType.video.rawValue`, and the coordinator's
    /// delete path parses it back out to decide whether a fallback metadata
    /// fetch is worth it.
    private let videoRecordName = MediaRecordName.componentRecordName(mediaID: "vid", type: .video)

    // MARK: - The write rule

    func testChunkingPolicyMatrix() {
        let threshold = Int64(SeekableEncryptedFormat.threshold)
        // Videos at/above threshold chunk on local and CloudKit backends.
        XCTAssertTrue(VideoChunkingPolicy.appliesIgnoringToggle(mediaType: .video, plaintextLength: threshold, storageType: .cloudKit))
        XCTAssertTrue(VideoChunkingPolicy.appliesIgnoringToggle(mediaType: .video, plaintextLength: threshold + 1, storageType: .local))
        // Below threshold never chunks.
        XCTAssertFalse(VideoChunkingPolicy.appliesIgnoringToggle(mediaType: .video, plaintextLength: threshold - 1, storageType: .cloudKit))
        // Photos never chunk, no matter the size.
        XCTAssertFalse(VideoChunkingPolicy.appliesIgnoringToggle(mediaType: .photo, plaintextLength: threshold * 4, storageType: .cloudKit))
        // iCloud Drive is excluded: an ENC3 file synced to a device on an older
        // app version would be unreadable there.
        XCTAssertFalse(VideoChunkingPolicy.appliesIgnoringToggle(mediaType: .video, plaintextLength: threshold * 4, storageType: .icloud))
        XCTAssertFalse(VideoChunkingPolicy.appliesIgnoringToggle(mediaType: .video, plaintextLength: threshold * 4, storageType: nil))
    }

    // MARK: - uploadChunks (the production upload)

    func testUploadChunksWritesOnlyChunkRecords() async throws {
        let blob = try makeBlob(bytes: 5_000, chunkSize: 1_000)
        try await makeChunkStore().uploadChunks(enc3FileURL: blob.url, mediaRecordName: "m1", progress: { _ in })

        XCTAssertEqual(savedRecords.filter { $0.recordType == ChunkedBlobSchema.Chunk.recordType }.count, 5)
        XCTAssertEqual(savedRecords.count, 5,
                       "the product plane commits via EncMedia, so the blob plane writes chunks and nothing else")
    }

    func testRetryUploadsOnlyTheMissingChunks() async throws {
        let blob = try makeBlob(bytes: 10_000, chunkSize: 1_000)
        let store = makeChunkStore()
        try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "m1", progress: { _ in })

        // Model an interrupted upload: chunks 3 and 7 never landed.
        mock.removeRecord(named: "m1#c3")
        mock.removeRecord(named: "m1#c7")
        mock.resetObservations()

        try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "m1", progress: { _ in })

        let resaved = savedRecords.map(\.recordID.recordName).sorted()
        XCTAssertEqual(resaved, ["m1#c3", "m1#c7"],
                       "resume-by-probe must skip every chunk a previous attempt committed")
    }

    func testCompletedUploadRetriesSaveNothing() async throws {
        let blob = try makeBlob(bytes: 4_000, chunkSize: 1_000)
        let store = makeChunkStore()
        try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "m1", progress: { _ in })
        mock.resetObservations()

        try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "m1", progress: { _ in })

        XCTAssertTrue(savedRecords.isEmpty, "a fully-committed upload's retry is probe-only")
    }

    func testSilentlyDroppedChunkFailsTheUploadLoudly() async throws {
        let blob = try makeBlob(bytes: 3_000, chunkSize: 1_000)
        mock.dropFromSaveResult = 1

        do {
            try await makeChunkStore().uploadChunks(enc3FileURL: blob.url, mediaRecordName: "m1", progress: { _ in })
            XCTFail("a save that returns fewer records than it was given must throw")
        } catch let error as ChunkedBlobError {
            guard case .saveVerificationFailed = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testUploadedChunksReassembleByteIdentically() async throws {
        let blob = try makeBlob(bytes: 7_500, chunkSize: 1_000)
        let store = makeChunkStore()
        let header = try await store.uploadChunks(enc3FileURL: blob.url, mediaRecordName: "m1", progress: { _ in })

        var reassembled = header.encoded()
        for index in 0..<header.chunkCount {
            reassembled.append(try await store.fetchChunk(mediaRecordName: "m1", index: index))
        }
        XCTAssertEqual(reassembled, try Data(contentsOf: blob.url),
                       "header bytes + chunks in order must reproduce the exact original ENC3 file")

        // And the reassembled bytes decrypt to the original plaintext.
        let roundTrip = tempDir.appendingPathComponent("roundtrip.enc3")
        try reassembled.write(to: roundTrip)
        let reader = try SeekableEncryptedReader.forFile(roundTrip, keyBytes: key)
        let plainURL = tempDir.appendingPathComponent("roundtrip.plain")
        try await reader.decryptToFile(destination: plainURL)
        XCTAssertEqual(try Data(contentsOf: plainURL), blob.plaintext)
    }

    // MARK: - Zone latch

    private final class ThrowingZoneProvisioner: RecordZoneProvisioning {
        var error: Error = CKError(.networkFailure)
        func saveZone(_ zone: CKRecordZone) async throws { throw error }
        func deleteZone(_ zoneID: CKRecordZone.ID) async throws { throw error }
    }

    func testZoneCreateFailureDoesNotLatchTheCreatedFlag() async throws {
        let store = CloudKitChunkedBlobStore(container: makeContainer(),
                                             adapter: mock,
                                             zoneProvisioner: ThrowingZoneProvisioner(),
                                             defaults: defaults)
        do {
            try await store.ensureZoneExists()
            XCTFail("a failed zone create must propagate")
        } catch {
            // Expected. The flag must NOT be set, or the install could never
            // write a chunk again.
            XCTAssertFalse(defaults.bool(forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey))
        }

        // A later attempt with a working provisioner succeeds and latches.
        let healthy = makeChunkStore()
        try await healthy.ensureZoneExists()
        XCTAssertTrue(defaults.bool(forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey))
    }

    // MARK: - EncMedia as the commit record

    private func makeMediaStore(chunkStore: CloudKitChunkedBlobStore) -> CloudKitMediaStore {
        CloudKitMediaStore(container: makeContainer(),
                           adapter: mock,
                           defaults: defaults,
                           chunkStore: chunkStore)
    }

    func testChunkedUploadCommitsWithEncMediaLastAndNoEncBlob() async throws {
        let blob = try makeBlob(bytes: 6_000, chunkSize: 1_000)
        let store = makeMediaStore(chunkStore: makeChunkStore())

        let upload = CloudKitMediaUpload(albumID: "album-hash",
                                         mediaID: "vid-1",
                                         mediaType: .video,
                                         createdAt: Date(),
                                         sizeBytes: 6_000,
                                         encryptedFileURL: blob.url,
                                         encryptedThumbURL: nil,
                                         recordName: "vid-1#2",
                                         keyFingerprint: "",
                                         chunkCount: blob.header.chunkCount,
                                         plaintextLength: Int64(blob.header.plaintextLength))
        _ = try await store.upload(upload, progress: { _ in })

        // The commit record is the LAST save: until it lands a partial chunk
        // upload reads as "not chunked yet".
        let lastBatch = try XCTUnwrap(mock.savedRecordBatches.last)
        XCTAssertEqual(lastBatch.map(\.recordType), [CloudKitSchema.EncMedia.recordType])

        let record = lastBatch[0]
        XCTAssertNil(record[CloudKitSchema.EncMedia.encBlob], "a chunked record carries no monolithic blob")
        XCTAssertEqual(record[CloudKitSchema.EncMedia.chunkCount] as? Int64, Int64(blob.header.chunkCount))
        XCTAssertEqual(record[CloudKitSchema.EncMedia.plaintextLength] as? Int64, Int64(blob.header.plaintextLength))
        XCTAssertEqual(record[CloudKitSchema.EncMedia.encHeader] as? Data, blob.header.encoded())
        XCTAssertEqual(record.recordID.zoneID.zoneName, CloudKitSchema.zoneName)

        let chunkRecords = savedRecords.filter { $0.recordType == ChunkedBlobSchema.Chunk.recordType }
        XCTAssertEqual(chunkRecords.count, blob.header.chunkCount)
        XCTAssertTrue(chunkRecords.allSatisfy { $0.recordID.zoneID.zoneName == ChunkedBlobSchema.zoneName })
    }

    func testMonolithicUploadStillCarriesEncBlobAndNoChunkFields() async throws {
        let file = tempDir.appendingPathComponent("small.bin")
        try fixture(bytes: 500).write(to: file)
        let store = makeMediaStore(chunkStore: makeChunkStore())

        let upload = CloudKitMediaUpload(albumID: "album-hash",
                                         mediaID: "pic-1",
                                         mediaType: .photo,
                                         createdAt: Date(),
                                         sizeBytes: 500,
                                         encryptedFileURL: file,
                                         encryptedThumbURL: nil,
                                         recordName: "pic-1#1")
        _ = try await store.upload(upload, progress: { _ in })

        let record = try XCTUnwrap(savedRecords.first { $0.recordType == CloudKitSchema.EncMedia.recordType })
        XCTAssertNotNil(record[CloudKitSchema.EncMedia.encBlob])
        XCTAssertNil(record[CloudKitSchema.EncMedia.chunkCount])
        XCTAssertNil(record[CloudKitSchema.EncMedia.encHeader])
    }

    // MARK: - Reading a chunked video back out of CloudKit

    /// Everything a read needs, built fresh — no `chunkInfo` learned from an
    /// upload, no cached ciphertext. That is what a relaunch leaves behind, and
    /// what a second device never had.
    private func makeColdCoordinator(albumID: String) -> CloudKitSyncCoordinator {
        let indexURL = tempDir.appendingPathComponent("index-\(UUID().uuidString).encindex")
        let queueSuite = "ck-e2e-delete-\(UUID().uuidString)"
        deleteQueueSuites.append(queueSuite)
        return CloudKitSyncCoordinator(
            albumID: albumID,
            store: makeMediaStore(chunkStore: makeChunkStore()),
            cache: CloudKitBlobCache(baseDir: tempDir.appendingPathComponent("cache-\(UUID().uuidString)"),
                                     maxBytes: 100 * 1024 * 1024),
            indexStore: MediaIndexStore(keyBytes: key, indexURL: indexURL),
            bus: FileOperationBus(),
            uploadQueue: CloudKitUploadQueue(baseDir: tempDir.appendingPathComponent("queue-\(UUID().uuidString)")),
            deleteQueue: CloudKitMediaDeleteQueue(suiteName: queueSuite),
            chunkStore: makeChunkStore()
        )
    }

    private var deleteQueueSuites: [String] = []

    private func uploadChunkedVideo(bytes: Int = 6_000,
                                    chunkSize: Int = 1_000,
                                    albumID: String = "album-hash") async throws
        -> (url: URL, header: SeekableEncryptedHeader, plaintext: Data) {
        let blob = try makeBlob(bytes: bytes, chunkSize: chunkSize)
        let store = makeMediaStore(chunkStore: makeChunkStore())
        let upload = CloudKitMediaUpload(albumID: albumID,
                                        mediaID: "vid",
                                        mediaType: .video,
                                        createdAt: Date(),
                                        sizeBytes: Int64((try Data(contentsOf: blob.url)).count),
                                        encryptedFileURL: blob.url,
                                        encryptedThumbURL: nil,
                                        recordName: videoRecordName,
                                        keyFingerprint: "",
                                        chunkCount: blob.header.chunkCount,
                                        plaintextLength: Int64(blob.header.plaintextLength))
        _ = try await store.upload(upload, progress: { _ in })
        return blob
    }

    /// The end-to-end failure this whole path exists to prevent: a chunked video
    /// uploaded, then opened by a reader holding nothing in memory. It failed with
    /// "Record or asset not found" — `fetchRecordMetadata` did not request
    /// `chunkCount`, so the record read back as monolithic and the reader went
    /// looking for an `encBlob` a chunked record deliberately never carries.
    func testChunkedVideoIsReadableByAColdReader() async throws {
        let blob = try await uploadChunkedVideo()
        let coordinator = makeColdCoordinator(albumID: "album-hash")

        let local = try await coordinator.ensureBlobLocal(recordName: videoRecordName,
                                                          albumID: "album-hash",
                                                          progress: { _ in })

        XCTAssertEqual(try Data(contentsOf: local), try Data(contentsOf: blob.url),
                       "the reassembled ENC3 must be byte-identical to what was uploaded")

        // And it actually plays: the bytes decrypt back to the original video.
        let encrypted = EncryptedMedia(source: .url(local), mediaType: .video, id: "vid")
        let handler = SecretFileHandler(keyBytes: key,
                                        source: encrypted,
                                        targetURL: tempDir.appendingPathComponent("played.mov"))
        let cleartext = try await handler.decryptToURL()
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(cleartext.url)), blob.plaintext)
    }

    /// Streaming is the path the Lightbox prefers, and it opens on the header
    /// alone. A cold reader that cannot see `encHeader` silently falls back to
    /// downloading the whole video — which is the slow path at best and, when the
    /// record reads as monolithic, no path at all.
    func testColdReaderCanOpenAChunkedVideoForStreaming() async throws {
        let blob = try await uploadChunkedVideo()
        let coordinator = makeColdCoordinator(albumID: "album-hash")

        let info = try await coordinator.chunkedBlobInfo(recordName: videoRecordName)
        let resolved = try XCTUnwrap(info, "a cold reader could not tell this record was chunked at all")
        XCTAssertEqual(resolved.chunkCount, blob.header.chunkCount)
        XCTAssertEqual(resolved.encHeader, blob.header.encoded(),
                       "without the header bytes there is nothing to open a streaming session with")
    }

    /// A sync runs on launch, before anything is played. It used to make things
    /// worse rather than better: the change feed did not carry `chunkCount`
    /// either, so every pass concluded "not chunked" and cleared the geometry the
    /// coordinator was holding — including the geometry an upload had just put
    /// there. Playing after a sync had to keep working, not just playing cold.
    func testASyncPassLeavesAChunkedVideoPlayable() async throws {
        let blob = try await uploadChunkedVideo()
        let coordinator = makeColdCoordinator(albumID: "album-hash")

        try await coordinator.sync(albumID: "album-hash")

        let afterSync = try await coordinator.chunkedBlobInfo(recordName: videoRecordName)
        let info = try XCTUnwrap(afterSync, "the sync pass erased the record's chunk geometry")
        XCTAssertEqual(info.chunkCount, blob.header.chunkCount)

        let local = try await coordinator.ensureBlobLocal(recordName: videoRecordName,
                                                          albumID: "album-hash",
                                                          progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: local), try Data(contentsOf: blob.url))
    }

    /// The other half of the same bug, and the one that does not announce itself:
    /// a delete reads the chunk count to know what to reclaim. Reading 0 removes
    /// the commit record and strands every chunk in the blob zone — and once the
    /// commit record is gone nothing can say how many there were.
    func testDeletingAChunkedVideoColdReclaimsEveryChunkRecord() async throws {
        let blob = try await uploadChunkedVideo()
        let coordinator = makeColdCoordinator(albumID: "album-hash")

        try await coordinator.remove(recordName: videoRecordName, albumID: "album-hash")

        let leftovers = mock.allRecords.filter { $0.recordType == ChunkedBlobSchema.Chunk.recordType }
        XCTAssertTrue(leftovers.isEmpty,
                      "\(leftovers.count) of \(blob.header.chunkCount) chunk records survived the delete, "
                      + "unreachable now that the record naming them is gone")
        XCTAssertNil(mock.allRecords.first { $0.recordID.recordName == videoRecordName },
                     "the commit record itself must go too")
    }

    // MARK: - Upload queue geometry

    func testEnqueuePersistsChunkGeometryBeforeAnyChunkIsSaved() async throws {
        let blob = try makeBlob(bytes: 3_000, chunkSize: 1_000)
        let queueDir = tempDir.appendingPathComponent("queue", isDirectory: true)
        let queue = CloudKitUploadQueue(baseDir: queueDir)

        let upload = CloudKitMediaUpload(albumID: "a",
                                         mediaID: "vid",
                                         mediaType: .video,
                                         createdAt: Date(),
                                         sizeBytes: 3_000,
                                         encryptedFileURL: blob.url,
                                         encryptedThumbURL: nil,
                                         recordName: videoRecordName,
                                         keyFingerprint: "",
                                         chunkCount: 3,
                                         plaintextLength: 3_000)
        _ = try await queue.enqueue(upload)

        // Geometry survives a relaunch (a fresh queue over the same directory).
        let relaunched = CloudKitUploadQueue(baseDir: queueDir)
        let pendingItem = await relaunched.pendingItem(recordName: videoRecordName)
        let item = try XCTUnwrap(pendingItem)
        XCTAssertEqual(item.chunkCount, 3)
        XCTAssertEqual(item.plaintextLength, 3_000)

        // And the rebuilt upload carries it back into the drain.
        let rebuilt = await relaunched.rebuild(item, thumbURL: nil)
        XCTAssertEqual(rebuilt.chunkCount, 3)
        XCTAssertEqual(rebuilt.plaintextLength, 3_000)
    }

    // MARK: - Delete queue geometry

    func testDeleteQueueCarriesChunkCountAndMigratesLegacyEntries() {
        let suiteName = makeIsolatedSuiteName()
        let isolated = UserDefaults(suiteName: suiteName)!
        // A v1 build left bare record names behind.
        isolated.set(["old#1", "old#2"], forKey: "cloudkit_pending_media_deletes_v1")

        let queue = CloudKitMediaDeleteQueue(suiteName: suiteName)
        queue.enqueue(videoRecordName, chunkCount: 12)

        let entries = Dictionary(uniqueKeysWithValues: queue.pendingEntries().map { ($0.recordName, $0.chunkCount) })
        XCTAssertEqual(entries[videoRecordName], 12)
        XCTAssertEqual(entries["old#1"], 0, "v1 entries predate chunked storage and migrate as monolithic")
        XCTAssertEqual(entries["old#2"], 0)
        XCTAssertNil(isolated.stringArray(forKey: "cloudkit_pending_media_deletes_v1"), "the legacy key is retired")

        // Unknown geometry can be resolved later, but never the reverse.
        queue.enqueue("unknown#2", chunkCount: CloudKitMediaDeleteQueue.unknownChunkCount)
        queue.updateChunkCount(7, for: "unknown#2")
        queue.enqueue("unknown#2", chunkCount: CloudKitMediaDeleteQueue.unknownChunkCount)
        let resolved = queue.pendingEntries().first { $0.recordName == "unknown#2" }
        XCTAssertEqual(resolved?.chunkCount, 7, "a resolved count must not be overwritten by a later unknown")
    }

    // MARK: - Read paths

    func testSecretFileHandlerDecryptsENC3ToURL() async throws {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date(timeIntervalSince1970: 1_000_000)
        let metadataJSON = try SeekableEncryptedFormat.encodeMetadata(metadata)
        let blob = try makeBlob(bytes: 5_500, chunkSize: 1_000, metadata: metadataJSON)

        let encrypted = EncryptedMedia(source: .url(blob.url), mediaType: .video, id: "vid")
        let target = tempDir.appendingPathComponent("decrypted.mov")
        let handler = SecretFileHandler(keyBytes: key, source: encrypted, targetURL: target)
        let cleartext = try await handler.decryptToURL()

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cleartext.url)), blob.plaintext,
                       "the format-agnostic handler must sniff ENC3 and decrypt it")
    }

    func testSecretFileHandlerDecryptsENC3InMemory() async throws {
        let blob = try makeBlob(bytes: 2_048, chunkSize: 512)
        let encrypted = EncryptedMedia(source: .url(blob.url), mediaType: .video, id: "vid")
        let handler = SecretFileHandler(keyBytes: key, source: encrypted)
        let cleartext = try await handler.decryptInMemory()
        XCTAssertEqual(cleartext.data, blob.plaintext)
    }

    func testSecretFileHandlerRejectsENC3WithWrongKey() async throws {
        let blob = try makeBlob(bytes: 2_000, chunkSize: 1_000)
        let wrongKey = [UInt8](repeating: 0x55, count: 32)
        let encrypted = EncryptedMedia(source: .url(blob.url), mediaType: .video, id: "vid")
        let handler = SecretFileHandler(keyBytes: wrongKey, source: encrypted)
        do {
            _ = try await handler.decryptInMemory()
            XCTFail("a wrong key must fail chunk authentication")
        } catch {
            // Expected.
        }
    }

    func testMetadataReaderReadsENC3Metadata() async throws {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date(timeIntervalSince1970: 1_699_000_000)
        let metadataJSON = try SeekableEncryptedFormat.encodeMetadata(metadata)
        let blob = try makeBlob(bytes: 1_500, chunkSize: 1_000, metadata: metadataJSON)

        let read = try await EncryptedMetadataHandler().readMetadata(from: blob.url, keyBytes: key)
        XCTAssertEqual(read?.captureDate, metadata.captureDate)
    }

    func testDetectFileVersionReportsENC3() throws {
        let blob = try makeBlob(bytes: 1_000, chunkSize: 1_000)
        XCTAssertEqual(try EncryptedMetadataHandler().detectFileVersion(from: blob.url), 3)
    }

    // MARK: - Key stamp and discovery

    func testKeyStampRoundTripsOnENC3WithoutCorruptingChunks() async throws {
        let blob = try makeBlob(bytes: 2_000, chunkSize: 1_000)

        XCTAssertNil(KeyStampSlot.readStamp(url: blob.url), "fresh ENC3 is unstamped")

        KeyStampSlot.writeStamp(0xDEADBEEF, url: blob.url)

        XCTAssertEqual(KeyStampSlot.readStamp(url: blob.url), 0xDEADBEEF)

        let reader = try SeekableEncryptedReader.forFile(blob.url, keyBytes: key)
        let plain = try await reader.plaintextChunk(at: 0)
        XCTAssertFalse(plain.isEmpty, "stamped ENC3 must still decrypt — the stamp is AAD-excluded")
    }

    func testFirstBlockProbeAuthenticatesENC3WithTheRightKeyOnly() throws {
        let blob = try makeBlob(bytes: 3_000, chunkSize: 1_000)

        KeyStampSlot.writeStamp(0xCAFEBABE, url: blob.url)

        let probe = try XCTUnwrap(FirstBlockProbe(url: blob.url))
        XCTAssertEqual(probe.stamp, 0xCAFEBABE, "ENC3 stamp lives in the mutable plaintext block")
        XCTAssertTrue(probe.authenticates(keyBytes: key))
        XCTAssertFalse(probe.authenticates(keyBytes: [UInt8](repeating: 0x66, count: 32)))
    }

    // MARK: - Delete ordering

    /// Records the interleaving of EncMedia deletes and chunk deletes.
    private final class RecordingChunkStore: ChunkedBlobStoring, @unchecked Sendable {
        let log: CallLog
        init(log: CallLog) { self.log = log }

        func uploadChunks(enc3FileURL: URL, mediaRecordName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
            throw ChunkedBlobError.accountUnavailable
        }
        func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
            throw ChunkedBlobError.chunkNotFound(mediaRecordName)
        }
        func delete(mediaRecordName: String, chunkCount: Int) async throws {
            log.append("chunks:\(mediaRecordName):\(chunkCount)")
        }
    }

    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ entry: String) { lock.withLock { entries.append(entry) } }
        var all: [String] { lock.withLock { entries } }
    }

    func testChunkedDeleteRemovesTheCommitRecordFirstThenTheChunks() async throws {
        let store = MockCloudKitMediaStore()
        let log = CallLog()
        let chunkStore = RecordingChunkStore(log: log)
        let indexURL = tempDir.appendingPathComponent("index.encindex")
        let indexStore = MediaIndexStore(keyBytes: Array(repeating: 7, count: 32), indexURL: indexURL)
        let cache = CloudKitBlobCache(baseDir: tempDir.appendingPathComponent("cache"), maxBytes: 100_000_000)
        let deleteQueue = CloudKitMediaDeleteQueue(suiteName: makeIsolatedSuiteName())
        let coordinator = CloudKitSyncCoordinator(albumID: "a1",
                                                  store: store,
                                                  cache: cache,
                                                  indexStore: indexStore,
                                                  bus: FileOperationBus(),
                                                  deleteQueue: deleteQueue,
                                                  chunkStore: chunkStore)

        // The record is a chunked video the server knows about.
        store.metadataToReturn = [CloudKitMediaMetadata(recordName: videoRecordName,
                                                        albumID: "a1",
                                                        mediaID: "vid",
                                                        mediaType: .video,
                                                        createdAt: Date(),
                                                        sizeBytes: 10,
                                                        creationDeviceID: "d",
                                                        schemaVersion: 1,
                                                        keyFingerprint: "",
                                                        recordChangeTag: "t1",
                                                        chunkCount: 4,
                                                        plaintextLength: 4_000)]
        store.onDelete = { name in log.append("record:\(name)") }

        try await coordinator.remove(recordName: videoRecordName, albumID: "a1")

        XCTAssertEqual(log.all, ["record:\(videoRecordName)", "chunks:\(videoRecordName):4"],
                       "the commit record must go first, so a crash leaves invisible orphans, never a truncated-looking video")
        XCTAssertTrue(deleteQueue.pendingEntries().isEmpty, "a fully-applied delete leaves nothing queued")
    }
}
