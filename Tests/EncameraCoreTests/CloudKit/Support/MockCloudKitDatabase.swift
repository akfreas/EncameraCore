//
//  MockCloudKitDatabase.swift
//  EncameraCoreTests
//
//  In-memory fake of `CloudKitDatabaseAdapter` plus small CloudKit test helpers,
//  so the store can be exercised offline with no iCloud account.
//

import Foundation
import CloudKit
@testable import EncameraCore

// MARK: - Account / zone stubs (reused across CloudKit tests)

struct StubAccountStatusProvider: AccountStatusProviding {
    let status: CKAccountStatus
    func currentAccountStatus() async throws -> CKAccountStatus { status }
}

final class StubZoneProvisioner: RecordZoneProvisioning {
    /// Every zone create it was asked for, in order — the evidence a test needs to
    /// prove a store either did or did not spend a round trip on the zone.
    private(set) var savedZoneIDs: [CKRecordZone.ID] = []
    private(set) var deletedZoneIDs: [CKRecordZone.ID] = []

    func saveZone(_ zone: CKRecordZone) async throws { savedZoneIDs.append(zone.zoneID) }
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws { deletedZoneIDs.append(zoneID) }
}

// MARK: - Mock adapter

final class MockCloudKitDatabase: CloudKitDatabaseAdapter {

    // Captured inputs
    private(set) var savedRecordBatches: [[CKRecord]] = []
    private(set) var deletedRecordIDBatches: [[CKRecord.ID]] = []
    private(set) var lastSavePolicy: CKModifyRecordsOperation.RecordSavePolicy?
    private(set) var lastQueryDesiredKeys: [CKRecord.FieldKey]?
    private(set) var lastFetchDesiredKeys: [CKRecord.FieldKey]?
    private(set) var lastFetchQualityOfService: QualityOfService?
    private(set) var lastQueryQualityOfService: QualityOfService?
    private(set) var cancelAllCalled = false

    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private(set) var fetchCount = 0

    /// Record names the server currently holds. `save` inserts, `delete` removes.
    private(set) var storedRecordIDs: Set<CKRecord.ID> = []

    /// Asset bytes read at save time, keyed by field, for the last save.
    /// CloudKit reads an asset's file while the operation runs, so a test that
    /// asserts on the uploaded bytes has to see them here: the store deletes the
    /// private snapshot it uploaded from as soon as `upload` returns.
    private(set) var lastSavedAssetPayloads: [CKRecord.FieldKey: Data] = [:]

    // Programmable behavior
    var saveError: Error?
    /// Models the server's uniqueness constraint: saving a record name it already
    /// holds fails with `serverRecordChanged` (the 14/2004 shape) instead of
    /// silently overwriting.
    var rejectsSavesOfOccupiedRecordNames = false
    /// Errors for successive `save` calls, consumed from the front (`nil` = that
    /// attempt succeeds). Lets a test model a save that fails once and succeeds on
    /// the retry; falls back to `saveError` once exhausted.
    var saveErrorSequence: [Error?] = []
    var deleteError: Error?
    var fetchError: Error?
    var queryError: Error?
    var zoneChangesError: Error?

    var stubbedQueryRecords: [CKRecord] = []
    var stubbedFetchRecords: [CKRecord.ID: CKRecord] = [:]
    var stubbedZoneChanges: ZoneChangesResult?
    var saveProgressValues: [Double] = []
    var fetchProgressValues: [Double] = []

    func save(records: [CKRecord],
              savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
              perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord] {
        saveCount += 1
        lastSavePolicy = savePolicy
        savedRecordBatches.append(records)
        lastSavedAssetPayloads = [:]
        for record in records {
            for key in record.allKeys() {
                guard let url = (record[key] as? CKAsset)?.fileURL,
                      let data = try? Data(contentsOf: url) else { continue }
                lastSavedAssetPayloads[key] = data
            }
            for value in saveProgressValues { perRecordProgress(record.recordID, value) }
        }
        if rejectsSavesOfOccupiedRecordNames,
           let occupied = records.first(where: { storedRecordIDs.contains($0.recordID) }) {
            throw CKErrorFactory.error(.serverRecordChanged,
                                       userInfo: [CKRecordChangedErrorServerRecordKey: occupied])
        }
        let attemptError = saveErrorSequence.isEmpty ? saveError : saveErrorSequence.removeFirst()
        if let attemptError { throw attemptError }
        for record in records { storedRecordIDs.insert(record.recordID) }
        return records
    }

    func delete(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        deleteCount += 1
        deletedRecordIDBatches.append(recordIDs)
        if let deleteError { throw deleteError }
        for recordID in recordIDs { storedRecordIDs.remove(recordID) }
        return recordIDs
    }

    func fetch(recordIDs: [CKRecord.ID],
               desiredKeys: [CKRecord.FieldKey]?,
               qualityOfService: QualityOfService,
               perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord.ID: CKRecord] {
        fetchCount += 1
        lastFetchDesiredKeys = desiredKeys
        lastFetchQualityOfService = qualityOfService
        for recordID in recordIDs {
            for value in fetchProgressValues { perRecordProgress(recordID, value) }
        }
        if let fetchError { throw fetchError }
        var result: [CKRecord.ID: CKRecord] = [:]
        for recordID in recordIDs {
            guard let record = stubbedFetchRecords[recordID] else { continue }
            result[recordID] = Self.projected(record, desiredKeys: desiredKeys)
        }
        return result
    }

    func query(recordType: String,
               predicate: NSPredicate,
               zoneID: CKRecordZone.ID,
               desiredKeys: [CKRecord.FieldKey]?,
               qualityOfService: QualityOfService) async throws -> [CKRecord] {
        lastQueryDesiredKeys = desiredKeys
        lastQueryQualityOfService = qualityOfService
        if let queryError { throw queryError }
        return stubbedQueryRecords.map { Self.projected($0, desiredKeys: desiredKeys) }
    }

    func fetchZoneChanges(zoneID: CKRecordZone.ID,
                          since token: CKServerChangeToken?,
                          desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneChangesResult {
        if let zoneChangesError { throw zoneChangesError }
        return stubbedZoneChanges ?? ZoneChangesResult(changed: [],
                                                       deleted: [],
                                                       token: token,
                                                       moreComing: false)
    }

    private(set) var savedSubscriptions: [CKSubscription] = []
    var saveSubscriptionError: Error?
    func saveSubscription(_ subscription: CKSubscription) async throws {
        if let saveSubscriptionError { throw saveSubscriptionError }
        savedSubscriptions.append(subscription)
    }

    func cancelAll() { cancelAllCalled = true }

    /// Drops every field the caller did not ask for, which is what real CloudKit
    /// does: `desiredKeys` is a projection, and an unrequested field comes back
    /// indistinguishable from one that was never written. A mock that hands back
    /// whole records instead makes any omission from a `desiredKeys` list invisible
    /// to the whole suite — the read side of chunked video storage shipped broken
    /// behind exactly that blind spot.
    private static func projected(_ record: CKRecord, desiredKeys: [CKRecord.FieldKey]?) -> CKRecord {
        guard let desiredKeys, let copy = record.copy() as? CKRecord else { return record }
        let requested = Set(desiredKeys)
        for key in copy.allKeys() where !requested.contains(key) {
            copy[key] = nil
        }
        return copy
    }
}

// MARK: - Record-building helpers

enum CloudKitTestFactory {
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: CloudKitSchema.zoneName) }

    static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    /// A chunked (ENC3) media record: header fields set, and — as production
    /// writes it — no `encBlob` at all.
    static func chunkedEncMediaRecord(recordName: String,
                                      albumID: String,
                                      chunkCount: Int = 3,
                                      plaintextLength: Int64 = 12_000_000,
                                      encHeader: Data = Data([0x45, 0x4E, 0x43, 0x33])) -> CKRecord {
        let record = encMediaRecord(recordName: recordName,
                                    albumID: albumID,
                                    mediaType: .video,
                                    sizeBytes: plaintextLength + 1024)
        record[CloudKitSchema.EncMedia.chunkCount] = Int64(chunkCount) as CKRecordValue
        record[CloudKitSchema.EncMedia.plaintextLength] = plaintextLength as CKRecordValue
        record[CloudKitSchema.EncMedia.encHeader] = encHeader as CKRecordValue
        return record
    }

    static func encMediaRecord(recordName: String,
                               albumID: String,
                               mediaType: MediaType = .photo,
                               createdAt: Date = Date(timeIntervalSince1970: 1_000),
                               sizeBytes: Int64 = 1234,
                               keyFingerprint: String? = nil) -> CKRecord {
        let record = CKRecord(recordType: CloudKitSchema.EncMedia.recordType, recordID: recordID(recordName))
        record[CloudKitSchema.EncMedia.albumID] = albumID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaID] = recordName as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaType] = Int64(mediaType.rawValue) as CKRecordValue
        record[CloudKitSchema.EncMedia.createdAt] = createdAt as CKRecordValue
        record[CloudKitSchema.EncMedia.sizeBytes] = sizeBytes as CKRecordValue
        record[CloudKitSchema.EncMedia.creationDevice] = "test-device" as CKRecordValue
        record[CloudKitSchema.EncMedia.schemaVersion] = CloudKitSchema.currentSchemaVersion as CKRecordValue
        // Left off entirely by default, so the default fixture models a record
        // written before `keyFingerprint` existed.
        if let keyFingerprint { record[CloudKitSchema.EncMedia.keyFingerprint] = keyFingerprint as CKRecordValue }
        return record
    }

    static func encAlbumRecord(albumID: String,
                               encName: String = "cipher",
                               createdAt: Date = Date(timeIntervalSince1970: 1_000),
                               isHidden: Bool = false,
                               keyFingerprint: String? = nil) -> CKRecord {
        let record = CKRecord(recordType: CloudKitSchema.EncAlbum.recordType, recordID: recordID(albumID))
        record[CloudKitSchema.EncAlbum.encName] = encName as CKRecordValue
        record[CloudKitSchema.EncAlbum.createdAt] = createdAt as CKRecordValue
        record[CloudKitSchema.EncAlbum.isHidden] = (isHidden ? 1 : 0) as CKRecordValue
        record[CloudKitSchema.EncAlbum.schemaVersion] = CloudKitSchema.currentSchemaVersion as CKRecordValue
        // Same convention as `encMediaRecord`: absent by default == pre-field record.
        if let keyFingerprint { record[CloudKitSchema.EncAlbum.keyFingerprint] = keyFingerprint as CKRecordValue }
        return record
    }
}

// MARK: - Synthetic CKError construction

enum CKErrorFactory {
    static func error(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> Error {
        NSError(domain: CKError.errorDomain, code: code.rawValue, userInfo: userInfo)
    }
}
