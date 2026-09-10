//
//  FakeAssetDatabase.swift
//  EncameraCoreTests
//
//  An in-memory CloudKit stand-in that persists CKAsset BYTES, not just record
//  references.
//
//  `MockCloudKitDatabase` retains the `CKRecord` it was handed, which is enough
//  for index-field tests but not for asset ones: `CloudKitChunkedBlobStore.upload`
//  writes each chunk to a scratch directory, hands CloudKit a `CKAsset` pointing
//  at it, and deletes the scratch once the save returns. That is correct — real
//  CloudKit reads the bytes during the save operation — but it leaves the mock
//  holding assets whose files are gone, so a later fetch reads nothing.
//
//  This double copies asset bytes at save time into storage it owns and hands
//  back a fresh file URL on fetch, which is also closer to how CloudKit actually
//  behaves: you never get the file you uploaded back, you get a new cache file.
//

import Foundation
import CloudKit
@testable import EncameraCore

final class FakeAssetDatabase: CloudKitDatabaseAdapter, @unchecked Sendable {

    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord] = [:]
    private let storageDir: URL

    // Observability for assertions.
    private(set) var savedRecordBatches: [[CKRecord]] = []
    private(set) var deletedRecordIDBatches: [[CKRecord.ID]] = []
    private(set) var fetchCount = 0
    private(set) var lastFetchDesiredKeys: [CKRecord.FieldKey]?
    private(set) var lastFetchQualityOfService: QualityOfService?
    /// Every record name fetched, in order.
    private(set) var fetchedRecordNames: [String] = []

    var saveError: Error?
    var fetchError: Error?
    /// Drops this many records from each save's returned array while still
    /// persisting them — models CloudKit reporting success without returning
    /// every record, which the store's save verification must catch.
    var dropFromSaveResult = 0

    init() {
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-ck-assets-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: storageDir) }

    var allRecords: [CKRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.values)
    }

    // NSLock.lock()/unlock() are unavailable from async contexts, so every locked
    // section lives in a synchronous helper the async requirement calls through.

    func save(records batch: [CKRecord],
              savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
              perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord] {
        if let saveError { throw saveError }
        performSave(batch, perRecordProgress: perRecordProgress)
        return dropFromSaveResult > 0 ? Array(batch.dropLast(dropFromSaveResult)) : batch
    }

    /// Clears the observation lists (not the records), so a test can assert on
    /// exactly the traffic one call produced.
    func resetObservations() {
        lock.lock(); defer { lock.unlock() }
        savedRecordBatches = []
        deletedRecordIDBatches = []
        fetchCount = 0
        fetchedRecordNames = []
    }

    /// Removes one persisted record, so a test can model a partially-committed
    /// upload whose retry must re-save only what is missing.
    func removeRecord(named recordName: String) {
        lock.lock(); defer { lock.unlock() }
        if let key = records.keys.first(where: { $0.recordName == recordName }) {
            records[key] = nil
        }
    }

    private func performSave(_ batch: [CKRecord],
                             perRecordProgress: (CKRecord.ID, Double) -> Void) {
        lock.lock(); defer { lock.unlock() }
        savedRecordBatches.append(batch)
        for record in batch {
            records[record.recordID] = persistingAssets(of: record)
            perRecordProgress(record.recordID, 1.0)
        }
    }

    func delete(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        performDelete(recordIDs)
        return recordIDs
    }

    private func performDelete(_ recordIDs: [CKRecord.ID]) {
        lock.lock(); defer { lock.unlock() }
        deletedRecordIDBatches.append(recordIDs)
        for id in recordIDs { records[id] = nil }
    }

    func fetch(recordIDs: [CKRecord.ID],
               desiredKeys: [CKRecord.FieldKey]?,
               qualityOfService: QualityOfService,
               perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord.ID: CKRecord] {
        if let fetchError { throw fetchError }
        return performFetch(recordIDs,
                            desiredKeys: desiredKeys,
                            qualityOfService: qualityOfService,
                            perRecordProgress: perRecordProgress)
    }

    private func performFetch(_ recordIDs: [CKRecord.ID],
                              desiredKeys: [CKRecord.FieldKey]?,
                              qualityOfService: QualityOfService,
                              perRecordProgress: (CKRecord.ID, Double) -> Void) -> [CKRecord.ID: CKRecord] {
        lock.lock(); defer { lock.unlock() }
        fetchCount += 1
        lastFetchDesiredKeys = desiredKeys
        lastFetchQualityOfService = qualityOfService
        var result: [CKRecord.ID: CKRecord] = [:]
        for id in recordIDs {
            fetchedRecordNames.append(id.recordName)
            if let record = records[id] {
                result[id] = Self.projected(record, desiredKeys: desiredKeys)
                perRecordProgress(id, 1.0)
            }
        }
        return result
    }

    /// Real CloudKit treats `desiredKeys` as a projection: an unrequested field
    /// arrives indistinguishable from one that was never written. Modelling that
    /// here is what lets a test tell a record apart from the subset of it the code
    /// actually asked for.
    static func projected(_ record: CKRecord, desiredKeys: [CKRecord.FieldKey]?) -> CKRecord {
        guard let desiredKeys, let copy = record.copy() as? CKRecord else { return record }
        let requested = Set(desiredKeys)
        for key in copy.allKeys() where !requested.contains(key) {
            copy[key] = nil
        }
        return copy
    }

    func query(recordType: String,
               predicate: NSPredicate,
               zoneID: CKRecordZone.ID,
               desiredKeys: [CKRecord.FieldKey]?,
               qualityOfService: QualityOfService) async throws -> [CKRecord] {
        performQuery(recordType, desiredKeys: desiredKeys)
    }

    private func performQuery(_ recordType: String, desiredKeys: [CKRecord.FieldKey]?) -> [CKRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values
            .filter { $0.recordType == recordType }
            .map { Self.projected($0, desiredKeys: desiredKeys) }
    }

    /// Every record in the zone, projected to `desiredKeys` — enough for a sync to
    /// be a real leg of a test rather than a no-op. The token is ignored: a test
    /// asserting on what a sync DOES with the feed wants the feed populated on
    /// every pass, and one page always finishes the drain.
    func fetchZoneChanges(zoneID: CKRecordZone.ID,
                          since token: CKServerChangeToken?,
                          desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneChangesResult {
        ZoneChangesResult(changed: recordsInZone(zoneID, desiredKeys: desiredKeys),
                          deleted: [],
                          token: token,
                          moreComing: false)
    }

    private func recordsInZone(_ zoneID: CKRecordZone.ID, desiredKeys: [CKRecord.FieldKey]?) -> [CKRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values
            .filter { $0.recordID.zoneID == zoneID }
            .map { Self.projected($0, desiredKeys: desiredKeys) }
    }

    func saveSubscription(_ subscription: CKSubscription) async throws {}
    func cancelAll() {}

    /// Copies every asset's bytes into storage this double owns, so they outlive
    /// the caller's scratch directory.
    private func persistingAssets(of record: CKRecord) -> CKRecord {
        let copy = record.copy() as! CKRecord
        for key in record.allKeys() {
            guard let asset = record[key] as? CKAsset, let source = asset.fileURL else { continue }
            let destination = storageDir
                .appendingPathComponent("\(record.recordID.recordName)-\(key)-\(UUID().uuidString).bin")
            guard let data = try? Data(contentsOf: source) else { continue }
            try? data.write(to: destination)
            copy[key] = CKAsset(fileURL: destination)
        }
        return copy
    }
}
