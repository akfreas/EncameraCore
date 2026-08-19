//
//  CloudKitMediaDeleteQueue.swift
//  EncameraCore
//
//  Durable record of `EncMedia` deletes the server has not confirmed yet.
//  `CloudKitSyncCoordinator.remove` enqueues BEFORE issuing the delete, so an
//  intent formed offline (or killed mid-flight) survives relaunch; every sync
//  drains the queue before reading the change feed, and a record still queued is
//  not re-materialized from its still-live remote copy.
//
//  Process-wide and keyed by record name rather than per-coordinator, which is
//  what makes `upload` able to cancel a pending delete for a name it is
//  republishing: the migration back into iCloud runs on a coordinator it builds
//  for itself, so a queue owned by one coordinator instance could not be seen —
//  let alone cleared — by the other. That is exactly how a completed migration
//  left an album showing zero items.
//

import Foundation

public struct CloudKitMediaDeleteQueue: DebugPrintable {

    private static let storageKey = "cloudkit_pending_media_deletes_v1"

    /// `enqueue`/`remove` are read-modify-write over one defaults key, and the
    /// writers run on different executors (a delete on the caller's thread, the
    /// drain on the coordinator actor). Static because instances are constructed
    /// ad hoc around the same underlying key — without a shared lock an
    /// interleaving writes back a stale set and drops the other side's entry,
    /// losing exactly the delete intent this queue exists to keep.
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard) {
        self.defaults = defaults
    }

    /// Record names whose delete the server has not confirmed.
    public func pending() -> Set<String> {
        Self.lock.withLock { read() }
    }

    public func enqueue(_ recordName: String) {
        Self.lock.withLock {
            var set = read()
            guard set.insert(recordName).inserted else {
                // Already queued: an idempotent re-enqueue, not a lost write.
                printDebug("enqueue skip recordName=\(recordName) reason=alreadyQueued pending=\(set.count)")
                return
            }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("enqueue ok recordName=\(recordName) pending=\(set.count)")
        }
    }

    public func remove(_ recordName: String) {
        Self.lock.withLock {
            var set = read()
            guard set.remove(recordName) != nil else { return }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("remove ok recordName=\(recordName) pending=\(set.count)")
        }
    }

    private func read() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }
}
