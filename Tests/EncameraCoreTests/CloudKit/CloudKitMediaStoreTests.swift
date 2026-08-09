//
//  CloudKitMediaStoreTests.swift
//  EncameraCoreTests
//
//  Chunk 02 — exercises CloudKitMediaStore against an in-memory mock adapter.
//  No network, no iCloud account.
//

import XCTest
import CloudKit
@testable import EncameraCore

final class CloudKitMediaStoreTests: XCTestCase {

    // Reference box so a @Sendable progress closure can accumulate values.
    private final class Box: @unchecked Sendable { var values: [Double] = [] }

    private let tokenKey = "cloudkit_zone_change_token_v1"
    private let longLivedMapKey = "cloudkit_longlived_ops_v1"

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        makeIsolatedDefaults(name)
    }

    private func makeStore(account: CKAccountStatus = .available,
                           adapter: MockCloudKitDatabase,
                           defaults: UserDefaults) -> CloudKitMediaStore {
        let container = CloudKitContainer(accountStatusProvider: StubAccountStatusProvider(status: account),
                                          zoneProvisioner: StubZoneProvisioner(),
                                          defaults: defaults)
        return CloudKitMediaStore(container: container, adapter: adapter, defaults: defaults)
    }

    private func makeUpload(mediaID: String = "media-1",
                            albumID: String = "album-hash",
                            mediaType: MediaType = .video,
                            fileURL: URL = URL(fileURLWithPath: "/tmp/enc.blob"),
                            thumbURL: URL = URL(fileURLWithPath: "/tmp/enc.thumb"),
                            keyFingerprint: String = "") -> CloudKitMediaUpload {
        CloudKitMediaUpload(albumID: albumID,
                            mediaID: mediaID,
                            mediaType: mediaType,
                            createdAt: Date(timeIntervalSince1970: 555),
                            sizeBytes: 4096,
                            encryptedFileURL: fileURL,
                            encryptedThumbURL: thumbURL,
                            keyFingerprint: keyFingerprint)
    }

    /// Real keys, so assertions use the same fingerprint production writes
    /// (`PrivateKey.keychainLabel`).
    private let keyA = PrivateKey(name: "keyA",
                                  keyBytes: Array(repeating: 0x42, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 0))
    private let keyB = PrivateKey(name: "keyB",
                                  keyBytes: Array(repeating: 0x24, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 0))

    // MARK: - Upload

    func testUploadBuildsRecordWithBothAssetsAndIndexFields() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        let fileURL = URL(fileURLWithPath: "/tmp/enc-\(UUID()).blob")
        let thumbURL = URL(fileURLWithPath: "/tmp/enc-\(UUID()).thumb")

        let ref = try await store.upload(makeUpload(fileURL: fileURL, thumbURL: thumbURL), progress: { _ in })
        XCTAssertEqual(ref.recordName, "media-1")

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.albumID] as? String, "album-hash")
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.mediaID] as? String, "media-1")
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.mediaType] as? Int64, Int64(MediaType.video.rawValue))
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.sizeBytes] as? Int64, 4096)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.schemaVersion] as? Int64, CloudKitSchema.currentSchemaVersion)

        let blob = saved[CloudKitSchema.EncMedia.encBlob] as? CKAsset
        let thumb = saved[CloudKitSchema.EncMedia.encThumbnail] as? CKAsset
        XCTAssertEqual(blob?.fileURL, fileURL)
        XCTAssertEqual(thumb?.fileURL, thumbURL)

        XCTAssertEqual(mock.lastSavePolicy?.rawValue,
                       CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged.rawValue)
    }

    func testUploadReportsProgressMonotonic0to1() async throws {
        let mock = MockCloudKitDatabase()
        mock.saveProgressValues = [0.0, 0.4, 1.0]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let box = Box()
        _ = try await store.upload(makeUpload(), progress: { box.values.append($0) })

        XCTAssertEqual(box.values, [0.0, 0.4, 1.0])
        XCTAssertEqual(box.values.last, 1.0)
    }

    func testAccountUnavailableShortCircuits() async {
        let mock = MockCloudKitDatabase()
        let store = makeStore(account: .noAccount, adapter: mock, defaults: freshDefaults())

        do {
            _ = try await store.upload(makeUpload(), progress: { _ in })
            XCTFail("Expected accountUnavailable")
        } catch let error as CloudKitMediaStoreError {
            guard case .accountUnavailable = error else { return XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(mock.saveCount, 0, "No op should be issued when the account is unavailable")
    }

    // MARK: - Metadata sync

    func testFetchMetadataExcludesBlobAsset() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let withoutThumb = try await store.fetchMetadata(albumID: "a1", includeThumbnail: false)
        XCTAssertEqual(withoutThumb.count, 1)
        XCTAssertEqual(mock.lastQueryDesiredKeys?.contains(CloudKitSchema.EncMedia.encBlob), false)
        XCTAssertEqual(mock.lastQueryDesiredKeys?.contains(CloudKitSchema.EncMedia.encThumbnail), false)

        _ = try await store.fetchMetadata(albumID: "a1", includeThumbnail: true)
        XCTAssertEqual(mock.lastQueryDesiredKeys?.contains(CloudKitSchema.EncMedia.encBlob), false,
                       "encBlob must never be eagerly requested")
        XCTAssertEqual(mock.lastQueryDesiredKeys?.contains(CloudKitSchema.EncMedia.encThumbnail), true)
    }

    func testFetchMetadataFiltersTombstones() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1"),
            CloudKitTestFactory.encMediaRecord(recordName: "m2", albumID: "a1", deletedAt: Date())
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let meta = try await store.fetchMetadata(albumID: "a1", includeThumbnail: false)
        XCTAssertEqual(meta.map { $0.recordName }, ["m1"])
    }

    // MARK: - Key fingerprint (ENC-70)

    func testUploadSetsKeyFingerprintOnRecord() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.upload(makeUpload(keyFingerprint: keyA.keychainLabel), progress: { _ in })

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.keyFingerprint] as? String, keyA.keychainLabel)
        XCTAssertNotEqual(keyA.keychainLabel, keyB.keychainLabel,
                          "The fixture keys must have distinct fingerprints for this to mean anything")
    }

    /// An unknown key leaves the field absent rather than writing "", so an unstamped
    /// new record reads the same as a legacy one — both mean "unknown".
    func testUploadOmitsKeyFingerprintWhenUnknown() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.upload(makeUpload(keyFingerprint: ""), progress: { _ in })

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertFalse(saved.allKeys().contains(CloudKitSchema.EncMedia.keyFingerprint))
    }

    /// A record written before the field existed still decodes to full metadata.
    func testRecordWithoutFingerprintFieldStillLoads() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [CloudKitTestFactory.encMediaRecord(recordName: "legacy", albumID: "a1")]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let meta = try await store.fetchMetadata(albumID: "a1", includeThumbnail: false)
        XCTAssertEqual(meta.map { $0.recordName }, ["legacy"])
        XCTAssertEqual(meta.first?.sizeBytes, 1234)
    }

    func testFetchFingerprintCensusCountsPerKey() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1", keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encMediaRecord(recordName: "m2", albumID: "a1", keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encMediaRecord(recordName: "m3", albumID: "a2", keyFingerprint: keyB.keychainLabel)
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 3,
                                        fingerprints: [keyA.keychainLabel: 2, keyB.keychainLabel: 1]))
    }

    /// Unknown does not become a bucket of its own, and a tombstoned record is not
    /// media the user still has. `mediaCount: 3` pins "records exist but none of
    /// them names a key", which the fingerprint map alone cannot express.
    func testFetchFingerprintCensusSkipsTombstonesAndUnknownRecords() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encMediaRecord(recordName: "live", albumID: "a1", keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encMediaRecord(recordName: "dead", albumID: "a1",
                                               deletedAt: Date(), keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encMediaRecord(recordName: "legacy", albumID: "a1"),
            CloudKitTestFactory.encMediaRecord(recordName: "blank", albumID: "a1", keyFingerprint: "")
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 3, fingerprints: [keyA.keychainLabel: 1]))
    }

    /// Counting downloads no media and issues no save, so no `CKAsset` is rewritten.
    func testFetchFingerprintCensusFetchesNoAssets() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1", keyFingerprint: keyA.keychainLabel)
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.fetchFingerprintCensus()

        let desired = try XCTUnwrap(mock.lastQueryDesiredKeys)
        XCTAssertFalse(desired.contains(CloudKitSchema.EncMedia.encBlob))
        XCTAssertFalse(desired.contains(CloudKitSchema.EncMedia.encThumbnail))
        XCTAssertEqual(mock.fetchCount, 0, "Counting must not fetch records by ID")
        XCTAssertEqual(mock.saveCount, 0, "Counting must never rewrite a record, and so never an asset")
    }

    /// A container whose schema cannot answer the query yet (record type or
    /// `createdAt` index not deployed) degrades to `.indexUnavailable` rather than
    /// throwing.
    func testFetchFingerprintCensusDegradesWhenSchemaNotReady() async throws {
        for code in [CKError.Code.invalidArguments, .unknownItem] {
            let mock = MockCloudKitDatabase()
            mock.queryError = CKErrorFactory.error(code)
            let store = makeStore(adapter: mock, defaults: freshDefaults("degrade-\(code.rawValue)"))

            let census = try await store.fetchFingerprintCensus()
            XCTAssertEqual(census, .indexUnavailable,
                           "\(code) must degrade to 'I could not tell', not 'no data' and not a throw")
        }
    }

    /// A real I/O failure still surfaces rather than degrading.
    func testFetchFingerprintCensusStillThrowsOnRealFailure() async {
        let mock = MockCloudKitDatabase()
        mock.queryError = CKErrorFactory.error(.quotaExceeded)
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        do {
            _ = try await store.fetchFingerprintCensus()
            XCTFail("Expected the quota error to propagate")
        } catch let error as CloudKitMediaStoreError {
            guard case .quotaExceeded = error else { return XCTFail("Wrong case: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveAlbumSetsKeyFingerprint() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        try await store.saveAlbum(CloudKitAlbumUpload(albumID: "album-hash",
                                                      encName: "cipher",
                                                      createdAt: Date(timeIntervalSince1970: 100),
                                                      isHidden: false,
                                                      keyFingerprint: keyA.keychainLabel))

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertEqual(saved.recordType, CloudKitSchema.EncAlbum.recordType)
        XCTAssertEqual(saved[CloudKitSchema.EncAlbum.keyFingerprint] as? String, keyA.keychainLabel)
    }

    /// A caller with no fingerprint to offer must not clear one an earlier save
    /// established — absent stays absent, present stays present.
    func testSaveAlbumOmitsKeyFingerprintWhenUnknown() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        try await store.saveAlbum(CloudKitAlbumUpload(albumID: "album-hash",
                                                      encName: "cipher",
                                                      createdAt: Date(timeIntervalSince1970: 100),
                                                      isHidden: false))

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertFalse(saved.allKeys().contains(CloudKitSchema.EncAlbum.keyFingerprint))
    }

    /// The album record is the one place the fingerprint survives when an album has
    /// no live media, so `fetchAllAlbums` must read it back — and a pre-field record
    /// must come back `nil` ("unknown"), never "".
    func testFetchAllAlbumsReadsKeyFingerprintBack() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encAlbumRecord(albumID: "stamped", keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encAlbumRecord(albumID: "legacy")
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let albums = try await store.fetchAllAlbums()
        XCTAssertEqual(albums.first { $0.albumID == "stamped" }?.keyFingerprint, keyA.keychainLabel)
        let legacy = try XCTUnwrap(albums.first { $0.albumID == "legacy" })
        XCTAssertNil(legacy.keyFingerprint)
    }

    // MARK: - Lazy asset fetch

    func testFetchBlobCopiesOutOfTempURL() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ck-temp-\(UUID()).bin")
        let payload = Data("ciphertext".utf8)
        try payload.write(to: temp)

        let record = CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")
        record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: temp)

        let mock = MockCloudKitDatabase()
        mock.stubbedFetchRecords = [CloudKitTestFactory.recordID("m1"): record]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ck-dest-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        try await store.fetchBlob(recordName: "m1", to: dest, progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        // The copy must survive deletion of CloudKit's temp file.
        try FileManager.default.removeItem(at: temp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: dest), payload)

        XCTAssertEqual(mock.lastFetchDesiredKeys, [CloudKitSchema.EncMedia.encBlob])
    }

    // MARK: - Delete / tombstone

    func testDeleteIsAtomicSingleOp() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        try await store.delete(recordName: "m1")

        XCTAssertEqual(mock.deleteCount, 1)
        XCTAssertEqual(mock.fetchCount, 0, "No separate blob op — delete removes the record and both assets atomically")
        XCTAssertEqual(mock.deletedRecordIDBatches.first?.first, CloudKitTestFactory.recordID("m1"))
    }

    func testTombstoneSetsDeletedAtAndSaves() async throws {
        let record = CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")
        let mock = MockCloudKitDatabase()
        mock.stubbedFetchRecords = [CloudKitTestFactory.recordID("m1"): record]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        try await store.tombstone(recordName: "m1")

        XCTAssertEqual(mock.fetchCount, 1)
        let saved = try XCTUnwrap(mock.savedRecordBatches.last?.first)
        XCTAssertNotNil(saved[CloudKitSchema.EncMedia.deletedAt] as? Date)
    }

    // MARK: - Error mapping

    func testQuotaExceededMapsToNonRetryable() {
        let mapped = mapCKError(CKErrorFactory.error(.quotaExceeded))
        guard case .quotaExceeded = mapped else { return XCTFail("Expected quotaExceeded, got \(mapped)") }
        XCTAssertFalse(mapped.isRetryable)
    }

    func testRetryAfterIsParsed() {
        let mapped = mapCKError(CKErrorFactory.error(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 7.0]))
        guard case .retry(let after) = mapped else { return XCTFail("Expected retry, got \(mapped)") }
        XCTAssertEqual(after, 7.0)
        XCTAssertTrue(mapped.isRetryable)
    }

    func testPartialFailureKeepsSucceeded() {
        let itemError = CKErrorFactory.error(.serverRecordChanged)
        let mapped = mapCKError(CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CloudKitTestFactory.recordID("m1"): itemError]]
        ))
        guard case .partial(let failed) = mapped else { return XCTFail("Expected partial, got \(mapped)") }
        XCTAssertNotNil(failed["m1"], "The failed record must be reported")
        XCTAssertNil(failed["m2"], "Records not in partialErrors are considered succeeded")
    }

    func testZoneNotFoundMaps() {
        guard case .zoneNotFound = mapCKError(CKErrorFactory.error(.zoneNotFound)) else {
            return XCTFail("Expected zoneNotFound")
        }
        guard case .zoneNotFound = mapCKError(CKErrorFactory.error(.userDeletedZone)) else {
            return XCTFail("Expected zoneNotFound for userDeletedZone")
        }
    }

    func testChangeTokenExpiredMaps() {
        guard case .changeTokenExpired = mapCKError(CKErrorFactory.error(.changeTokenExpired)) else {
            return XCTFail("Expected changeTokenExpired")
        }
    }

    func testZoneScopedErrorsWrappedInPartialFailureUnwrap() {
        // CloudKit delivers zone-scoped errors at the op level wrapped in
        // `.partialFailure` — the typed cases must still come out, or the
        // token-expired full-resync and zone recreation never fire.
        let zoneID = CKRecordZone.ID(zoneName: CloudKitSchema.zoneName)
        let wrappedToken = CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [zoneID: CKErrorFactory.error(.changeTokenExpired)]]
        )
        guard case .changeTokenExpired = mapCKError(wrappedToken) else {
            return XCTFail("Expected changeTokenExpired out of a wrapped partial failure")
        }
        let wrappedZone = CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [zoneID: CKErrorFactory.error(.zoneNotFound)]]
        )
        guard case .zoneNotFound = mapCKError(wrappedZone) else {
            return XCTFail("Expected zoneNotFound out of a wrapped partial failure")
        }
        // A mixed bag must still surface as partial, not be misread as zone-scoped.
        let mixed = CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [
                CloudKitTestFactory.recordID("m1"): CKErrorFactory.error(.serverRecordChanged),
                CloudKitTestFactory.recordID("m2"): CKErrorFactory.error(.changeTokenExpired)
            ] as [AnyHashable: Error]]
        )
        guard case .partial = mapCKError(mixed) else {
            return XCTFail("Expected partial for heterogeneous failures")
        }
    }

    func testFetchChangesRecognizesTokenExpiryWrappedInPartialFailure() async {
        let mock = MockCloudKitDatabase()
        let zoneID = CKRecordZone.ID(zoneName: CloudKitSchema.zoneName)
        mock.zoneChangesError = CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [zoneID: CKErrorFactory.error(.changeTokenExpired)]]
        )
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        do {
            _ = try await store.fetchChanges(since: nil)
            XCTFail("Expected changeTokenExpired")
        } catch let error as CloudKitMediaStoreError {
            guard case .changeTokenExpired = error else { return XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testZoneNotFoundInvalidatesZoneAndSubscriptionFlags() async throws {
        let defaults = freshDefaults()
        let zoneKey = "cloudkit_zone_created_v1_" + CloudKitSchema.containerID
        let subKey = "cloudkit_zone_subscription_v1_" + CloudKitSchema.containerID
        defaults.set(true, forKey: zoneKey)
        defaults.set(true, forKey: subKey)

        let mock = MockCloudKitDatabase()
        mock.zoneChangesError = CKErrorFactory.error(.zoneNotFound)
        let store = makeStore(adapter: mock, defaults: defaults)

        do {
            _ = try await store.fetchChanges(since: nil)
            XCTFail("Expected zoneNotFound")
        } catch let error as CloudKitMediaStoreError {
            guard case .zoneNotFound = error else { return XCTFail("Wrong error: \(error)") }
        }

        XCTAssertFalse(defaults.bool(forKey: zoneKey),
                       "A gone zone must clear the zone-created flag so ensureZoneExists() re-provisions")
        XCTAssertFalse(defaults.bool(forKey: subKey),
                       "A gone zone must clear the subscription flag so registration re-runs")

        // With the stale flag cleared, registration actually happens again.
        try await store.registerZoneSubscription()
        XCTAssertEqual(mock.savedSubscriptions.count, 1)
    }

    func testRegisterZoneSubscriptionNoOpsWhenFlagAlreadySet() async throws {
        // The coordinator retries registration on every sync and relies on THIS
        // persisted-flag check to make the genuinely-registered case free.
        let defaults = freshDefaults()
        defaults.set(true, forKey: "cloudkit_zone_subscription_v1_" + CloudKitSchema.containerID)
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: defaults)

        try await store.registerZoneSubscription()

        XCTAssertTrue(mock.savedSubscriptions.isEmpty,
                      "an already-registered subscription must not be saved again")
    }

    func testCancelledErrorMaps() {
        guard case .cancelled = mapCKError(CKErrorFactory.error(.operationCancelled)) else {
            return XCTFail("Expected cancelled")
        }
    }

    func testNotAuthenticatedMapsToAccountUnavailable() {
        guard case .accountUnavailable = mapCKError(CKErrorFactory.error(.notAuthenticated)) else {
            return XCTFail("Expected accountUnavailable")
        }
    }

    // MARK: - Cancellation

    func testCancelAllInvokesAdapter() {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        store.cancelAll()
        XCTAssertTrue(mock.cancelAllCalled)
    }

    // MARK: - Delta sync

    func testFetchChangesMapsChangedAndDeleted() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedZoneChanges = ZoneChangesResult(
            changed: [CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")],
            deletedRecordNames: ["m2"],
            token: nil,
            moreComing: true
        )
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let changeSet = try await store.fetchChanges(since: nil)
        XCTAssertEqual(changeSet.changed.map { $0.recordName }, ["m1"])
        XCTAssertEqual(changeSet.deleted, ["m2"])
        XCTAssertTrue(changeSet.moreComing)
    }

    func testFetchChangesDoesNotPersistTokenOnFailure() async {
        let defaults = freshDefaults()
        let sentinel = Data([1, 2, 3])
        defaults.set(sentinel, forKey: tokenKey)

        let mock = MockCloudKitDatabase()
        mock.zoneChangesError = CKErrorFactory.error(.networkUnavailable)
        let store = makeStore(adapter: mock, defaults: defaults)

        do {
            _ = try await store.fetchChanges(since: nil)
            XCTFail("Expected a thrown error")
        } catch {
            // expected
        }
        XCTAssertEqual(defaults.data(forKey: tokenKey), sentinel,
                       "A failed fetch must not advance the persisted change token")
    }

    // MARK: - Interrupted uploads / legacy long-lived state (ENC-133)

    /// The crash was armed by *persisted* long-lived operation IDs that a later store
    /// construction handed back to CloudKit. Constructing a store must clear the map
    /// an older build left behind, so there is nothing left to hand back.
    func testConstructingAStoreClearsTheLegacyLongLivedOperationMap() {
        let defaults = freshDefaults()
        // Exactly what a kill mid-upload used to leave behind.
        defaults.set(["m1": "3090886DAE392CF7", "m2": "opB"], forKey: longLivedMapKey)

        _ = makeStore(adapter: MockCloudKitDatabase(), defaults: defaults)

        XCTAssertNil(defaults.object(forKey: longLivedMapKey),
                     "A stale long-lived operation map must not survive store construction")
    }

    /// Store construction used to kick off a CloudKit round-trip (fetch all
    /// long-lived operation IDs, then re-enqueue each). It must now be inert: the
    /// app builds one store per album namespace on launch, and every one of those
    /// re-enqueues was a chance to raise the uncatchable `CKException`.
    func testConstructingManyStoresIssuesNoCloudKitWork() async {
        let defaults = freshDefaults()
        defaults.set(["m1": "opA"], forKey: longLivedMapKey)
        let mock = MockCloudKitDatabase()

        for _ in 0..<5 {
            _ = makeStore(adapter: mock, defaults: defaults)
        }
        // Give any stray init-time Task a chance to run before asserting.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mock.saveCount, 0)
        XCTAssertEqual(mock.fetchCount, 0)
        XCTAssertEqual(mock.deleteCount, 0)
        XCTAssertNil(defaults.object(forKey: longLivedMapKey))
    }

    /// An upload killed part-way (here: the save fails, standing in for the process
    /// dying between issuing and completing it) must leave nothing behind that makes
    /// the next attempt at the same record misbehave — the retry is an ordinary save.
    func testInterruptedUploadLeavesNoStateThatBreaksTheNextSave() async throws {
        let defaults = freshDefaults()
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: defaults)

        mock.saveError = CKErrorFactory.error(.networkFailure)
        do {
            _ = try await store.upload(makeUpload(), progress: { _ in })
            XCTFail("Expected the interrupted upload to fail")
        } catch {
            // expected
        }
        XCTAssertNil(defaults.object(forKey: longLivedMapKey),
                     "An interrupted upload must not record a long-lived operation")

        // The resumed migration re-drives the same record.
        mock.saveError = nil
        let ref = try await store.upload(makeUpload(), progress: { _ in })

        XCTAssertEqual(ref.recordName, "media-1")
        XCTAssertEqual(mock.saveCount, 2, "The retry is a fresh, ordinary save")
        XCTAssertNil(defaults.object(forKey: longLivedMapKey))
    }

    /// The full repro shape: an upload is interrupted, the app is "relaunched"
    /// (fresh stores over the same app-group defaults), and the migration resumes.
    /// Nothing is re-enqueued and the resumed upload succeeds.
    func testRelaunchAfterAnInterruptedUploadResumesWithoutReattachingAnything() async throws {
        let defaults = freshDefaults()
        let firstMock = MockCloudKitDatabase()
        let firstStore = makeStore(adapter: firstMock, defaults: defaults)
        firstMock.saveError = CKErrorFactory.error(.networkFailure)
        _ = try? await firstStore.upload(makeUpload(), progress: { _ in })

        // Relaunch: the album list, albums sync and the migration each build a store.
        let secondMock = MockCloudKitDatabase()
        var stores: [CloudKitMediaStore] = []
        for _ in 0..<3 { stores.append(makeStore(adapter: secondMock, defaults: defaults)) }
        XCTAssertEqual(secondMock.saveCount, 0, "No store construction may issue a CloudKit operation")

        let ref = try await XCTUnwrap(stores.last).upload(makeUpload(), progress: { _ in })

        XCTAssertEqual(ref.recordName, "media-1")
        XCTAssertEqual(secondMock.saveCount, 1)
        XCTAssertNil(defaults.object(forKey: longLivedMapKey))
    }
}
