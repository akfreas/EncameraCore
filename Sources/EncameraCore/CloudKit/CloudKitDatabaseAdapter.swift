//
//  CloudKitDatabaseAdapter.swift
//  EncameraCore
//
//  The narrow database-operation surface `CloudKitMediaStore` talks to, plus the
//  production `CKDatabase`-backed implementation. Tests substitute an in-memory
//  fake (`MockCloudKitDatabase`) so CI never hits the network or needs an account.
//

import Foundation
import CloudKit

/// Result of one zone-changes delta fetch.
/// A record the zone reports as deleted.
///
/// The type matters as much as the name: the zone is shared between `EncMedia`
/// and `EncAlbum`, and CloudKit hands it to us in `recordWithIDWasDeletedBlock`.
/// Dropping it — as this adapter used to — is what forced album deletes onto a
/// query path that has no delete channel at all, and from there onto a tombstone.
public struct DeletedRecord: Equatable, Sendable {
    public let recordName: String
    public let recordType: String

    public init(recordName: String, recordType: String) {
        self.recordName = recordName
        self.recordType = recordType
    }
}

public struct ZoneChangesResult {
    public let changed: [CKRecord]
    public let deleted: [DeletedRecord]
    public let token: CKServerChangeToken?
    public let moreComing: Bool

    public init(changed: [CKRecord],
                deleted: [DeletedRecord],
                token: CKServerChangeToken?,
                moreComing: Bool) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

/// Everything the store needs from a CloudKit database, expressed at a level that
/// is trivial to fake. The store stays free of `CKOperation` wiring.
///
/// Deliberately offers no long-lived-operation surface. Long-lived `CKOperation`s
/// outlive the process and must be re-enqueued at most once per launch; adding one
/// that the daemon already considers running raises an `NSException` that Swift
/// cannot catch, so a second `add` is a guaranteed process kill. Since the store is
/// constructed many times per launch (one per album namespace) there is no safe
/// place to do that re-enqueue, and the durable `MigrationPlan` already provides the
/// resumability it would have bought. See ENC-133.
public protocol CloudKitDatabaseAdapter: AnyObject {
    func save(records: [CKRecord],
              savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
              perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord]

    func delete(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID]

    /// `qualityOfService` is a real throughput knob for asset transfers, not just a
    /// scheduling hint: raising it from `.userInitiated` to `.userInteractive` is
    /// widely reported to speed up `CKAsset` downloads several-fold. Callers that
    /// pull an asset a user is waiting on should ask for `.userInteractive`;
    /// background bookkeeping fetches should leave the default alone so they do not
    /// compete with it.
    func fetch(recordIDs: [CKRecord.ID],
               desiredKeys: [CKRecord.FieldKey]?,
               qualityOfService: QualityOfService,
               perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord.ID: CKRecord]

    /// Same `qualityOfService` contract as `fetch`: raise it when `desiredKeys`
    /// names an asset field, leave the default for index-only queries.
    func query(recordType: String,
               predicate: NSPredicate,
               zoneID: CKRecordZone.ID,
               desiredKeys: [CKRecord.FieldKey]?,
               qualityOfService: QualityOfService) async throws -> [CKRecord]

    func fetchZoneChanges(zoneID: CKRecordZone.ID,
                          since token: CKServerChangeToken?,
                          desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneChangesResult

    func saveSubscription(_ subscription: CKSubscription) async throws

    func cancelAll()
}

public extension CloudKitDatabaseAdapter {
    /// Default-QoS overload. A protocol requirement cannot carry a default argument,
    /// so the many metadata/bookkeeping call sites get one here and only the asset
    /// paths have to name a quality of service.
    func fetch(recordIDs: [CKRecord.ID],
               desiredKeys: [CKRecord.FieldKey]?,
               perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord.ID: CKRecord] {
        try await fetch(recordIDs: recordIDs,
                        desiredKeys: desiredKeys,
                        qualityOfService: .userInitiated,
                        perRecordProgress: perRecordProgress)
    }

    /// Default-QoS overload of `query`, for the same reason.
    func query(recordType: String,
               predicate: NSPredicate,
               zoneID: CKRecordZone.ID,
               desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
        try await query(recordType: recordType,
                        predicate: predicate,
                        zoneID: zoneID,
                        desiredKeys: desiredKeys,
                        qualityOfService: .userInitiated)
    }
}

// MARK: - Production implementation

/// Wraps a real `CKDatabase`, executing each call as a `CKOperation`.
public final class CKDatabaseAdapter: CloudKitDatabaseAdapter, DebugPrintable {

    private let database: CKDatabase

    private let lock = NSLock()
    private var inFlight: [CKOperation] = []

    public init(database: CKDatabase) {
        self.database = database
    }

    // MARK: Save / delete

    public func save(records: [CKRecord],
                     savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                     perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord] {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.savePolicy = savePolicy
        operation.qualityOfService = .userInitiated

        // `runCancellable`, like `fetch`: cancelling the awaiting task must stop an
        // in-flight save — a cancelled 100 MB chunk batch otherwise keeps
        // transferring invisibly to completion.
        return try await Self.runCancellable(operation) { continuation in
            // `configuration.isLongLived` stays at its default (false) on purpose —
            // see the protocol's note and ENC-133. A long-lived save survives app
            // termination in the daemon, but re-attaching to it on the next launch is
            // what crashed the app, and the migration checkpoint re-verifies and
            // re-drives an interrupted item anyway.

            var saved: [CKRecord] = []
            var perRecordFailures: [CKRecord.ID: Error] = [:]
            operation.perRecordProgressBlock = { record, fraction in
                perRecordProgress(record.recordID, fraction)
            }
            // A per-record failure used to be dropped on the floor here, leaving an
            // empty `saved` and no error — the caller then could not tell a record that
            // failed to save from one that saved and returned nothing. `referenceViolation`
            // (a dangling `parent`) lands exactly here.
            operation.perRecordSaveBlock = { recordID, result in
                switch result {
                case .success(let record):
                    saved.append(record)
                case .failure(let error):
                    perRecordFailures[recordID] = error
                    Self.printDebug("save per-record FAILED recordName=\(recordID.recordName) error=\(error)")
                }
            }
            operation.modifyRecordsResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success:
                    // The operation as a whole succeeded but individual records did not:
                    // surface the per-record failures rather than reporting success
                    // with nothing saved.
                    if !perRecordFailures.isEmpty {
                        Self.printDebug("save reported success with \(perRecordFailures.count) per-record failure(s): \(perRecordFailures.keys.map(\.recordName))")
                        continuation.resume(throwing: Self.perRecordSaveFailureError(perRecordFailures))
                    } else {
                        Self.printDebug("save ok records=\(saved.count)")
                        continuation.resume(returning: saved)
                    }
                case .failure(let error):
                    Self.printDebug("save FAILED records=\(records.map(\.recordID.recordName)) error=\(error) perRecordFailures=\(perRecordFailures.mapValues { "\($0)" })")
                    continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    /// The error surfaced when a `CKModifyRecordsOperation` reports overall
    /// success while individual records failed. Synthesized as `.partialFailure`
    /// carrying EVERY per-record error — the same shape a failed operation
    /// produces — so `mapCKError` yields a `.partial` that callers (the migration
    /// manager's `unwrapPartial`) resolve deterministically. Throwing one raw
    /// error via `Dictionary.first` would make quota-vs-conflict handling a coin
    /// flip on multi-record saves.
    static func perRecordSaveFailureError(_ failures: [CKRecord.ID: Error]) -> Error {
        NSError(domain: CKError.errorDomain,
                code: CKError.Code.partialFailure.rawValue,
                userInfo: [CKPartialErrorsByItemIDKey: failures])
    }

    public func delete(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.qualityOfService = .userInitiated

            var deleted: [CKRecord.ID] = []
            operation.perRecordDeleteBlock = { recordID, result in
                switch result {
                case .success: deleted.append(recordID)
                case .failure(let error): Self.printDebug("delete per-record FAILED recordName=\(recordID.recordName) error=\(error)")
                }
            }
            operation.modifyRecordsResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success: continuation.resume(returning: deleted.isEmpty ? recordIDs : deleted)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Fetch

    /// Fetches records, honoring task cancellation: a blob download the user
    /// cancelled must stop transferring, not keep running invisibly (which is
    /// exactly what happened before — the "cancelled" download finished anyway and
    /// the retry silently attached to it).
    public func fetch(recordIDs: [CKRecord.ID],
                      desiredKeys: [CKRecord.FieldKey]?,
                      qualityOfService: QualityOfService,
                      perRecordProgress: @escaping (CKRecord.ID, Double) -> Void) async throws -> [CKRecord.ID: CKRecord] {
        let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
        operation.desiredKeys = desiredKeys
        operation.qualityOfService = qualityOfService

        return try await Self.runCancellable(operation) { continuation in
            var fetched: [CKRecord.ID: CKRecord] = [:]
            operation.perRecordProgressBlock = { recordID, fraction in
                perRecordProgress(recordID, fraction)
            }
            operation.perRecordResultBlock = { recordID, result in
                if case .success(let record) = result {
                    // On iOS 18+ a CKAsset's staged file is only guaranteed valid
                    // inside this delivery block — the system may reclaim it any
                    // time after it returns, and callers read the fileURL after
                    // the whole operation completes. Snapshot every asset to a
                    // file we own, HERE, and hand back a record pointing at the
                    // copies (an APFS clone, so cost is near zero).
                    Self.snapshotAssets(of: record)
                    fetched[recordID] = record
                }
            }
            operation.fetchRecordsResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success: continuation.resume(returning: fetched)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    /// Where asset snapshots live. A directory of its own, because these files
    /// have to be reclaimable in bulk: they are created deep inside a CloudKit
    /// delivery block with no natural owner, and one left behind per fetched
    /// chunk means a leak that grows with every video played.
    public static var assetSnapshotDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ckassets", isDirectory: true)
    }

    /// Whether `url` names a file in the snapshot directory — i.e. one this
    /// process created and may freely move or delete. A `CKAsset` URL that fails
    /// this test still points at CloudKit's own staged file, which the system
    /// owns and reclaims on its own schedule.
    public static func isSnapshot(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.deletingLastPathComponent().standardizedFileURL == assetSnapshotDirectory.standardizedFileURL
    }

    /// Deletes one snapshot. Safe to call with any URL — a path outside the
    /// snapshot directory is ignored rather than deleted, so a caller that passes
    /// an un-snapshotted CloudKit URL cannot remove a file the system still owns.
    public static func discardSnapshot(at url: URL?) {
        guard let url, isSnapshot(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Replaces every `CKAsset` field on `record` with one pointing at a copy of
    /// the staged file in a directory this process owns. Must run inside the
    /// operation's per-record delivery block — see the call site. A failed copy
    /// leaves the original asset in place (the pre-fix behavior).
    ///
    /// The copy has to be reclaimed by whoever reads it (`discardSnapshot`), with
    /// `TempFileAccess.cleanupTemporaryFiles()` sweeping the directory as the
    /// backstop for anything that does not.
    static func snapshotAssets(of record: CKRecord) {
        let directory = assetSnapshotDirectory
        for key in record.allKeys() {
            guard let asset = record[key] as? CKAsset, let sourceURL = asset.fileURL else { continue }
            let destination = directory.appendingPathComponent("ckasset-\(UUID().uuidString)-\(key)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                record[key] = CKAsset(fileURL: destination)
            } catch {
                Self.printDebug("snapshotAssets FAILED recordName=\(record.recordID.recordName) key=\(key) raw=\(error)")
            }
        }
    }

    /// Bridges a `CKOperation` into async/await *with* cancellation: when the
    /// awaiting task is cancelled the operation is cancelled too, and CloudKit
    /// completes it with `.operationCancelled` — which resumes `start`'s
    /// continuation through the operation's own result block.
    ///
    /// `start` must configure the operation's result block to resume the
    /// continuation exactly once, then dispatch it.
    static func runCancellable<T>(_ operation: CKOperation,
                                  start: @escaping (CheckedContinuation<T, Error>) -> Void) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                start(continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    // MARK: Query (handles cursor paging)

    public func query(recordType: String,
                      predicate: NSPredicate,
                      zoneID: CKRecordZone.ID,
                      desiredKeys: [CKRecord.FieldKey]?,
                      qualityOfService: QualityOfService) async throws -> [CKRecord] {
        var all: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let (page, next) = try await runQuery(recordType: recordType,
                                                  predicate: predicate,
                                                  zoneID: zoneID,
                                                  desiredKeys: desiredKeys,
                                                  qualityOfService: qualityOfService,
                                                  cursor: cursor)
            all.append(contentsOf: page)
            cursor = next
        } while cursor != nil
        return all
    }

    private func runQuery(recordType: String,
                          predicate: NSPredicate,
                          zoneID: CKRecordZone.ID,
                          desiredKeys: [CKRecord.FieldKey]?,
                          qualityOfService: QualityOfService,
                          cursor: CKQueryOperation.Cursor?) async throws -> ([CKRecord], CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor = cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                operation = CKQueryOperation(query: CKQuery(recordType: recordType, predicate: predicate))
            }
            operation.zoneID = zoneID
            operation.desiredKeys = desiredKeys
            operation.qualityOfService = qualityOfService

            var records: [CKRecord] = []
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result { records.append(record) }
            }
            operation.queryResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success(let nextCursor): continuation.resume(returning: (records, nextCursor))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Zone changes

    public func fetchZoneChanges(zoneID: CKRecordZone.ID,
                                 since token: CKServerChangeToken?,
                                 desiredKeys: [CKRecord.FieldKey]?) async throws -> ZoneChangesResult {
        try await withCheckedThrowingContinuation { continuation in
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = token
            config.desiredKeys = desiredKeys
            let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                              configurationsByRecordZoneID: [zoneID: config])
            operation.qualityOfService = .userInitiated

            var changed: [CKRecord] = []
            var deleted: [DeletedRecord] = []
            var newToken: CKServerChangeToken? = token
            var moreComing = false
            var zoneError: Error?

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result { changed.append(record) }
            }
            // The second parameter is the deleted record's TYPE. Keeping it is what
            // lets a caller tell an album deletion from a media one — the whole
            // reason album deletes can live on this feed instead of needing a
            // server-side tombstone to be visible at all.
            operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                deleted.append(DeletedRecord(recordName: recordID.recordName, recordType: recordType))
            }
            operation.recordZoneChangeTokensUpdatedBlock = { _, serverToken, _ in
                if let serverToken = serverToken { newToken = serverToken }
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (serverChangeToken, _, moreComingFlag)):
                    newToken = serverChangeToken
                    moreComing = moreComingFlag
                case .failure(let error):
                    // Zone-scoped errors (`.changeTokenExpired`, `.zoneNotFound`)
                    // arrive HERE, not at the op level — there they'd be wrapped
                    // in `.partialFailure` and the token-expired recovery would
                    // never fire. Capture the bare error and throw it instead.
                    zoneError = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { [weak self] result in
                self?.untrack(operation)
                if let zoneError {
                    // We fetch exactly one zone, so its error IS the result.
                    continuation.resume(throwing: zoneError)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: ZoneChangesResult(changed: changed,
                                                                      deleted: deleted,
                                                                      token: newToken,
                                                                      moreComing: moreComing))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Subscriptions

    public func saveSubscription(_ subscription: CKSubscription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription],
                                                           subscriptionIDsToDelete: nil)
            operation.qualityOfService = .utility
            operation.modifySubscriptionsResultBlock = { [weak self] result in
                self?.untrack(operation)
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.track(operation)
            self.database.add(operation)
        }
    }

    // MARK: Cancellation / tracking

    public func cancelAll() {
        lock.lock()
        let operations = inFlight
        inFlight.removeAll()
        lock.unlock()
        operations.forEach { $0.cancel() }
    }

    private func track(_ operation: CKOperation) {
        lock.lock(); inFlight.append(operation); lock.unlock()
    }

    private func untrack(_ operation: CKOperation) {
        lock.lock(); inFlight.removeAll { $0 === operation }; lock.unlock()
    }
}
