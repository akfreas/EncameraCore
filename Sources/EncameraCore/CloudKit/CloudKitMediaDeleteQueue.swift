//
//  CloudKitMediaDeleteQueue.swift
//  EncameraCore
//
//  Both halves of an `EncMedia` delete, kept together and process-wide: the
//  durable record of deletes the server has not confirmed, and the session-scoped
//  `CloudKitKnownDeletedRecords` holding the mark that reads fail closed on and
//  the claim each delete is held under.
//
//  `CloudKitSyncCoordinator.remove` claims BEFORE issuing the delete, so an
//  intent formed offline (or killed mid-flight) survives relaunch; every sync
//  drains the queue before reading the change feed, and a record still queued is
//  not re-materialized from its still-live remote copy.
//
//  Keyed by record name rather than per-coordinator, which is what makes `upload`
//  able to cancel a pending delete for a name it is republishing: the migration
//  back into iCloud runs on a coordinator it builds for itself, so bookkeeping
//  owned by one coordinator instance could not be seen — let alone cleared — by
//  the other. That is how a completed migration left an album showing zero items,
//  and how the mark left by a move OUT of iCloud made every photo the move back
//  republished unreadable until the app was restarted.
//
//  The two halves only ever move together, which is why this type exposes no way
//  to set one alone. Separately they interleave into a record that is marked but
//  unqueued: refused for reads for the rest of the session AND never reclaimed
//  server-side — the same symptom, under a race.
//
//  Each entry carries the item's chunk geometry, captured from `EncMedia` before
//  that record is deleted: a chunked item's payload lives as `EncBlobChunk`
//  records in `EncameraBlobZone`, which nothing references and no cascade
//  reclaims — the queue entry is the only durable record of how many chunk
//  records the drain must delete.
//

import Foundation

/// `@unchecked Sendable` because both halves are safe to touch from anywhere:
/// `UserDefaults` is documented thread-safe, and the session state behind it is
/// reached only under this type's lock. Coordinators are separate actors holding
/// the same queue, so it crosses isolation boundaries by design.
public struct CloudKitMediaDeleteQueue: DebugPrintable, @unchecked Sendable {

    /// One unconfirmed delete: the `EncMedia` record plus its chunk geometry.
    public struct Entry: Equatable, Sendable {
        public let recordName: String
        /// `EncBlobChunk` records to reclaim after the `EncMedia` delete lands.
        /// 0 = monolithic (nothing in the blob zone). `unknownChunkCount` = the
        /// geometry could not be read when the intent was formed (offline);
        /// the drain resolves it with a metadata fetch before deleting.
        public let chunkCount: Int

        public init(recordName: String, chunkCount: Int) {
            self.recordName = recordName
            self.chunkCount = chunkCount
        }
    }

    /// Sentinel for "the delete was queued without reachable geometry".
    public static let unknownChunkCount = -1

    /// v1 stored a bare `[String]` of record names; v2 stores
    /// `[recordName: chunkCount]`. v1 entries are migrated on first read with
    /// chunk count 0 — every v1 entry predates chunked storage.
    private static let legacyStorageKey = "cloudkit_pending_media_deletes_v1"
    private static let storageKey = "cloudkit_pending_media_deletes_v2"

    /// Guards BOTH halves. Every mutation is a read-modify-write, and the writers
    /// run on different executors (a delete on the caller's thread, the drain on
    /// the coordinator actor). Static because instances are constructed ad hoc
    /// around the same underlying storage — without a shared lock an interleaving
    /// writes back a stale set and drops the other side's entry, losing exactly
    /// the delete intent this queue exists to keep.
    ///
    /// It is always the OUTER lock: the paired operations take it and then reach
    /// into `session`'s own lock, and nothing takes the two in the other order.
    private static let lock = NSLock()

    #if DEBUG
    /// Runs inside a paired update, between the session half and the queue half,
    /// with the lock held. Nil in production and never set by the app.
    ///
    /// A test installs it to prove the ordering contract directly: no other paired
    /// update can complete while one is between its halves. That is the property a
    /// split implementation breaks, and asserting it here is deterministic —
    /// racing two mutators and sampling for a torn read is not.
    static var pairedUpdateSeam: (@Sendable () -> Void)?
    #endif

    private let defaults: UserDefaults
    private let session: CloudKitKnownDeletedRecords

    /// The production queue: the app-group defaults and the session state paired
    /// with them.
    public init() {
        self.init(suiteName: UserDefaultUtils.appGroup)
    }

    /// A queue over `suiteName`. Both halves come from the suite name — the
    /// defaults for the durable half, `CloudKitKnownDeletedRecords.forSuite` for
    /// the session half — so two queues over the same suite are always backed by
    /// the same session state, and there is no way to express a private durable
    /// half with a shared session half (or the reverse).
    ///
    /// Tests use it with a suite of their own. `UserDefaults(suiteName:)` returns
    /// nil for a name that collides with the app's own bundle id, and silently
    /// falling back to `.standard` would hand a test the shared store it asked to
    /// be isolated from, so that is a hard stop rather than a default.
    init(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("No UserDefaults suite named \(suiteName) — a bundle id cannot be a suite name")
        }
        self.defaults = defaults
        self.session = .forSuite(suiteName)
    }

    // MARK: - Paired

    /// Marks `recordName` deleted locally and, unless the item never reached
    /// CloudKit, queues the server delete — in ONE lock acquisition. The returned
    /// claim is what `confirmDelete` must present to drop that queue entry.
    ///
    /// Atomic against `forgetDeletion` on purpose. As two separate operations a
    /// republish could clear the mark, this claim could then set it and queue, and
    /// the republish's queue drop could land last, leaving the record marked but
    /// unqueued: unreadable for the rest of the session and never reclaimed from
    /// the zone. The migration back into iCloud racing a user delete is exactly
    /// where that interleaving lives.
    @discardableResult
    func claimDeletion(of recordName: String, chunkCount: Int = 0, queueRemoteDelete: Bool) -> CloudKitDeleteClaim {
        Self.lock.withLock {
            let claim = session.claim(recordName)
            guard queueRemoteDelete else {
                printDebug("claimDeletion ok recordName=\(recordName) queued=false — nothing to delete remotely")
                return claim
            }
            #if DEBUG
            Self.pairedUpdateSeam?()
            #endif
            enqueueLocked(recordName, chunkCount: chunkCount)
            return claim
        }
    }

    /// Drops the queue entry for a delete the server has confirmed, but only if
    /// `claim` is still the live claim on the record.
    ///
    /// The compare is what closes an ABA: a delete can succeed server-side, the
    /// record can be republished and deleted again while this caller is suspended,
    /// and an unconditional drop would then remove the SECOND delete's intent —
    /// leaving the record marked, live in the zone, and refused for reads for the
    /// rest of the session with nothing left to retry.
    @discardableResult
    func confirmDelete(of recordName: String, claimedAs claim: CloudKitDeleteClaim) -> Bool {
        Self.lock.withLock {
            guard session.isCurrent(claim, for: recordName) else {
                printDebug("confirmDelete skip recordName=\(recordName) — superseded by a newer claim")
                return false
            }
            removeLocked(recordName)
            return true
        }
    }

    /// Drops both halves together, because the record is live again. Any claim
    /// outstanding on it is retired, so a delete still in flight cannot confirm
    /// away the intent of a delete issued after this republish.
    func forgetDeletion(of recordName: String) {
        Self.lock.withLock {
            session.release(recordName)
            #if DEBUG
            Self.pairedUpdateSeam?()
            #endif
            removeLocked(recordName)
        }
    }

    /// Marks `recordName` deleted without claiming or queueing it. Used for
    /// feed-observed deletes where no local `confirmDelete` will follow: reads
    /// fail closed, but the claim generation stays untouched so an in-flight
    /// local delete's confirmation is not stranded by a spurious bump.
    func markDeletedFromFeed(_ recordName: String) {
        Self.lock.withLock {
            session.markOnly(recordName)
        }
    }

    /// Drops the mark for a record the server has just reported as live, unless a
    /// delete is still queued for it — in which case the delete has not been
    /// issued yet and must keep winning.
    func clearKnownDeletedIfNotQueued(_ recordName: String) {
        Self.lock.withLock {
            guard read()[recordName] == nil else {
                printDebug("clearKnownDeleted skip recordName=\(recordName) reason=deleteStillQueued")
                return
            }
            guard !session.hasActiveClaim(recordName) else {
                printDebug("clearKnownDeleted skip recordName=\(recordName) reason=activeClaimOutstanding")
                return
            }
            session.unmark(recordName)
        }
    }

    // MARK: - Reads

    /// Whether a delete has already claimed this record name on this device.
    func isKnownDeleted(_ recordName: String) -> Bool {
        session.contains(recordName)
    }

    /// Record names whose delete the server has not confirmed.
    public func pending() -> Set<String> {
        Self.lock.withLock { Set(read().keys) }
    }

    /// Every unconfirmed delete with its chunk geometry.
    public func pendingEntries() -> [Entry] {
        Self.lock.withLock { read().map { Entry(recordName: $0.key, chunkCount: $0.value) } }
    }

    public func enqueue(_ recordName: String, chunkCount: Int = 0) {
        Self.lock.withLock {
            var map = read()
            if let existing = map[recordName] {
                let upgradeable = existing == Self.unknownChunkCount || existing == 0
                guard upgradeable, chunkCount != existing else {
                    printDebug("enqueue skip recordName=\(recordName) reason=alreadyQueued pending=\(map.count)")
                    return
                }
            }
            map[recordName] = chunkCount
            write(map)
            printDebug("enqueue ok recordName=\(recordName) chunkCount=\(chunkCount) pending=\(map.count)")
        }
    }

    /// Records geometry resolved after the fact (the drain fetched the record's
    /// metadata for an entry queued as unknown), so a crash between the
    /// `EncMedia` delete and the chunk deletes cannot lose the count.
    public func updateChunkCount(_ chunkCount: Int, for recordName: String) {
        Self.lock.withLock {
            var map = read()
            guard map[recordName] != nil else { return }
            map[recordName] = chunkCount
            write(map)
            printDebug("updateChunkCount ok recordName=\(recordName) chunkCount=\(chunkCount)")
        }
    }

    /// Every unconfirmed delete with the claim it is currently held under, so a
    /// drain that did not issue the claims can still confirm them by compare.
    func pendingClaims() -> [String: CloudKitDeleteClaim] {
        Self.lock.withLock {
            var claims: [String: CloudKitDeleteClaim] = [:]
            for recordName in read().keys {
                claims[recordName] = session.currentClaim(recordName)
            }
            return claims
        }
    }

    /// Both halves read together, so a caller cannot observe one without the
    /// other. Internal: the tests that pin the pairing are the only readers, and a
    /// production caller wanting one half has an accessor for it already.
    func deletionState(of recordName: String) -> (knownDeleted: Bool, queued: Bool) {
        Self.lock.withLock {
            (session.contains(recordName), read()[recordName] != nil)
        }
    }

    // MARK: - Storage

    private func enqueueLocked(_ recordName: String, chunkCount: Int = 0) {
        var map = read()
        if let existing = map[recordName] {
            let upgradeable = existing == Self.unknownChunkCount || existing == 0
            guard upgradeable, chunkCount != existing else {
                printDebug("enqueue skip recordName=\(recordName) reason=alreadyQueued pending=\(map.count)")
                return
            }
        }
        map[recordName] = chunkCount
        write(map)
        printDebug("enqueue ok recordName=\(recordName) chunkCount=\(chunkCount) pending=\(map.count)")
    }

    private func removeLocked(_ recordName: String) {
        var map = read()
        guard map.removeValue(forKey: recordName) != nil else { return }
        write(map)
        printDebug("remove ok recordName=\(recordName) pending=\(map.count)")
    }

    private func read() -> [String: Int] {
        var map = (defaults.dictionary(forKey: Self.storageKey) as? [String: Int]) ?? [:]
        // Fold in (and retire) any v1 entries left by an earlier build.
        if let legacy = defaults.stringArray(forKey: Self.legacyStorageKey), !legacy.isEmpty {
            for name in legacy where map[name] == nil { map[name] = 0 }
            defaults.set(map, forKey: Self.storageKey)
            defaults.removeObject(forKey: Self.legacyStorageKey)
            printDebug("read migrated \(legacy.count) v1 entries")
        }
        return map
    }

    private func write(_ map: [String: Int]) {
        defaults.set(map, forKey: Self.storageKey)
    }
}
