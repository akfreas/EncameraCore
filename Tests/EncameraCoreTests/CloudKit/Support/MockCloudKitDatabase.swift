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
    func saveZone(_ zone: CKRecordZone) async throws {}
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {}
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

    // Programmable behavior
    var saveError: Error?
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
        for record in records {
            for value in saveProgressValues { perRecordProgress(record.recordID, value) }
        }
        if let saveError { throw saveError }
        return records
    }

    func delete(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        deleteCount += 1
        deletedRecordIDBatches.append(recordIDs)
        if let deleteError { throw deleteError }
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
        for recordID in recordIDs where stubbedFetchRecords[recordID] != nil {
            result[recordID] = stubbedFetchRecords[recordID]
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
        return stubbedQueryRecords
    }

    func fetchZoneChanges(zoneID: CKRecordZone.ID,
                          since token: CKServerChangeToken?,
                          desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneChangesResult {
        if let zoneChangesError { throw zoneChangesError }
        return stubbedZoneChanges ?? ZoneChangesResult(changed: [],
                                                       deletedRecordNames: [],
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
}

// MARK: - Record-building helpers

enum CloudKitTestFactory {
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: CloudKitSchema.zoneName) }

    static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    static func encMediaRecord(recordName: String,
                               albumID: String,
                               mediaType: MediaType = .photo,
                               createdAt: Date = Date(timeIntervalSince1970: 1_000),
                               sizeBytes: Int64 = 1234,
                               deletedAt: Date? = nil,
                               keyFingerprint: String? = nil) -> CKRecord {
        let record = CKRecord(recordType: CloudKitSchema.EncMedia.recordType, recordID: recordID(recordName))
        record[CloudKitSchema.EncMedia.albumID] = albumID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaID] = recordName as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaType] = Int64(mediaType.rawValue) as CKRecordValue
        record[CloudKitSchema.EncMedia.createdAt] = createdAt as CKRecordValue
        record[CloudKitSchema.EncMedia.sizeBytes] = sizeBytes as CKRecordValue
        record[CloudKitSchema.EncMedia.creationDevice] = "test-device" as CKRecordValue
        record[CloudKitSchema.EncMedia.schemaVersion] = CloudKitSchema.currentSchemaVersion as CKRecordValue
        if let deletedAt { record[CloudKitSchema.EncMedia.deletedAt] = deletedAt as CKRecordValue }
        // Left off entirely by default, so the default fixture models a record
        // written before `keyFingerprint` existed.
        if let keyFingerprint { record[CloudKitSchema.EncMedia.keyFingerprint] = keyFingerprint as CKRecordValue }
        return record
    }

    static func encAlbumRecord(albumID: String,
                               encName: String = "cipher",
                               createdAt: Date = Date(timeIntervalSince1970: 1_000),
                               isHidden: Bool = false,
                               deletedAt: Date? = nil,
                               keyFingerprint: String? = nil) -> CKRecord {
        let record = CKRecord(recordType: CloudKitSchema.EncAlbum.recordType, recordID: recordID(albumID))
        record[CloudKitSchema.EncAlbum.encName] = encName as CKRecordValue
        record[CloudKitSchema.EncAlbum.createdAt] = createdAt as CKRecordValue
        record[CloudKitSchema.EncAlbum.isHidden] = (isHidden ? 1 : 0) as CKRecordValue
        record[CloudKitSchema.EncAlbum.schemaVersion] = CloudKitSchema.currentSchemaVersion as CKRecordValue
        if let deletedAt { record[CloudKitSchema.EncAlbum.deletedAt] = deletedAt as CKRecordValue }
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
