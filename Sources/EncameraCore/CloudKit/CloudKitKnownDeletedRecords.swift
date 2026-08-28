//
//  CloudKitKnownDeletedRecords.swift
//  EncameraCore
//
//  The session half of `CloudKitMediaDeleteQueue`, one instance per storage
//  suite: the record names a delete has claimed on this device, and the claim
//  each one is currently held under.
//
//  Reads fail closed on a marked name, so a delete that lands mid-fetch wins
//  instead of the fetched copy. The claim is what makes confirming a delete a
//  compare-and-clear: a confirmation can only drop the intent it was issued for,
//  never a newer one for a record that has since been republished and deleted
//  again.
//
//  Process-wide for the same reason the queue is: an album can be served by more
//  than one coordinator at a time — the registry's long-lived instance and the
//  private one `CloudKitMigrationManager` builds for a move back into iCloud —
//  and the coordinator that republishes a record name is not the one that marked
//  it. Held per instance, the mark a move OUT of iCloud left behind outlived the
//  move back, and the registry coordinator refused to read a photo that was live
//  again. Keyed by suite name so that the queue and the marks for one storage
//  suite can never come apart: same suite, same instance, always.
//
//  Deliberately NOT persisted, unlike the queue. This is a within-session race
//  guard, not an intent: the durable half is the queue, a mark is only ever
//  dropped (never acted on), and persisting one per deleted record would grow a
//  defaults key without bound for state a relaunch is entitled to forget.
//

import Foundation

/// Identifies one claim on a record's delete. Held by the claimant and presented
/// back when the server confirms, so a confirmation that arrives after the record
/// was republished and re-deleted cannot clear the newer claim's intent.
struct CloudKitDeleteClaim: Equatable, Sendable {
    let generation: UInt64
}

final class CloudKitKnownDeletedRecords: @unchecked Sendable {

    /// One instance per suite name, so two `CloudKitMediaDeleteQueue`s over the
    /// same durable storage always share the same session state. Isolating one
    /// half while inheriting the other shared is the split the pairing exists to
    /// prevent, and this is what makes it unrepresentable rather than merely
    /// discouraged. Instances live for the process — one of them in the app; a
    /// test suite name adds an empty one costing a dictionary entry.
    private static let registryLock = NSLock()
    private static var bySuite: [String: CloudKitKnownDeletedRecords] = [:]

    static func forSuite(_ suiteName: String) -> CloudKitKnownDeletedRecords {
        registryLock.withLock {
            if let existing = bySuite[suiteName] { return existing }
            let created = CloudKitKnownDeletedRecords()
            bySuite[suiteName] = created
            return created
        }
    }

    /// The production instance, paired with the app-group defaults.
    static var shared: CloudKitKnownDeletedRecords { forSuite(UserDefaultUtils.appGroup) }

    /// Coordinators are separate actors, so this is read and written from several
    /// executors at once. Always the INNER lock: the queue takes its own static
    /// lock first for anything that touches both halves.
    private let lock = NSLock()
    private var names: Set<String> = []
    /// Bumped on every claim and every republish, so a stale confirmation cannot
    /// match. Absent means "never claimed this session", which is generation 0 —
    /// what a queue entry restored from a previous launch is claimed under.
    private var generations: [String: UInt64] = [:]

    private init() {}

    func contains(_ recordName: String) -> Bool {
        lock.withLock { names.contains(recordName) }
    }

    /// Marks the record and takes the next claim on it.
    func claim(_ recordName: String) -> CloudKitDeleteClaim {
        lock.withLock {
            names.insert(recordName)
            let next = (generations[recordName] ?? 0) + 1
            generations[recordName] = next
            return CloudKitDeleteClaim(generation: next)
        }
    }

    /// The claim a queued record is currently held under, for a drain that did not
    /// issue the claim itself.
    func currentClaim(_ recordName: String) -> CloudKitDeleteClaim {
        lock.withLock { CloudKitDeleteClaim(generation: generations[recordName] ?? 0) }
    }

    /// Whether `claim` is still the live claim on the record.
    func isCurrent(_ claim: CloudKitDeleteClaim, for recordName: String) -> Bool {
        lock.withLock { (generations[recordName] ?? 0) == claim.generation }
    }

    /// Unmarks the record and retires every outstanding claim on it, because the
    /// record is live again.
    func release(_ recordName: String) {
        lock.withLock {
            names.remove(recordName)
            // Bump only what is already claimed. Inserting here would add an entry
            // per UPLOAD rather than per delete — every upload forgets a deletion
            // first, so an import of 10,000 photos would leave 10,000 of them — and
            // a record that was never claimed has no outstanding claim to retire.
            guard let current = generations[recordName] else { return }
            generations[recordName] = current + 1
        }
    }

    /// Whether a claim has ever been issued for `recordName` this session and has
    /// not been retired. Used by `clearKnownDeletedIfNotQueued` to avoid unmarking
    /// a record whose delete was claimed but never queued (wasPending path).
    func hasActiveClaim(_ recordName: String) -> Bool {
        lock.withLock { generations[recordName] != nil }
    }

    /// Inserts `recordName` into `names` without touching `generations`. Used for
    /// feed-observed deletes that need reads to fail closed but must not bump the
    /// claim generation — a bump would strand an in-flight local delete whose
    /// `confirmDelete(claimedAs:)` still holds the previous generation.
    func markOnly(_ recordName: String) {
        lock.withLock { names.insert(recordName) }
    }

    /// Unmarks without retiring the claim, for the sync paths that learn from the
    /// server that a record is live.
    func unmark(_ recordName: String) {
        lock.withLock { _ = names.remove(recordName) }
    }

    /// Empties everything. For tests: an instance outlives every one of them, so a
    /// name one test marks would otherwise make another test's read of the same
    /// name fail closed.
    func removeAll() {
        lock.withLock {
            names.removeAll()
            generations.removeAll()
        }
    }
}
