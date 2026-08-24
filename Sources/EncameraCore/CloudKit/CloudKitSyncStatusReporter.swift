//
//  CloudKitSyncStatusReporter.swift
//  EncameraCore
//
//  Carries CloudKit sync activity to the UI.
//

import Foundation
import Combine

/// What CloudKit sync is doing right now, as far as the user needs to know.
public enum CloudKitSyncActivity: Equatable, Sendable {

    /// Nothing in flight and nothing waiting.
    case idle
    /// Reconciling album existence and media indexes against the server.
    case checking
    /// Sending queued captures up. `total` is the size of the backlog this pass
    /// started with, so the fraction only ever moves forward within a pass.
    case uploading(completed: Int, total: Int)
    /// Uploads that have been abandoned (iCloud storage full) and will not retry
    /// on their own.
    case stalled(count: Int)

    /// Progress through the current upload pass, or nil when there is no
    /// determinate work to show a bar for.
    public var fractionCompleted: Double? {
        guard case .uploading(let completed, let total) = self, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// Publishes CloudKit sync activity for the home screen's status bar.
///
/// A shared singleton for the same reason as `LockedAlbumsReporter`: the
/// producers are actors owned by `EncameraApp` (`CloudKitAlbumsSync`) or global
/// singletons (`CloudKitUploader`), and the consumer is a view built
/// independently of both, so there is no common owner to inject through.
@MainActor
public final class CloudKitSyncStatusReporter: ObservableObject {

    public static let shared = CloudKitSyncStatusReporter()

    @Published public private(set) var isChecking: Bool = false
    @Published public private(set) var uploadsCompleted: Int = 0
    @Published public private(set) var uploadsTotal: Int = 0
    @Published public private(set) var stalledCount: Int = 0
    /// When the last reconcile finished, so the bar can say "synced just now"
    /// rather than simply vanishing. Nil until one completes this launch.
    @Published public private(set) var lastSyncedAt: Date?

    /// Pins the reported activity, ignoring every producer. Test-only: the real
    /// producers race any staged value — the empty upload drain that every launch
    /// kicks off reports "nothing pending" and would wipe a staged backlog before
    /// the bar could be read.
    @Published public private(set) var stagedActivity: CloudKitSyncActivity?

    /// Uploading outranks checking: the two overlap constantly (a reconcile ends
    /// by kicking the uploader) and a byte count is the more informative of the
    /// two. `stalled` only shows once nothing is moving, so a backlog that is
    /// draining is not also reported as stuck.
    public var activity: CloudKitSyncActivity {
        if let stagedActivity {
            return stagedActivity
        }
        if uploadsTotal > 0 {
            return .uploading(completed: uploadsCompleted, total: uploadsTotal)
        }
        if isChecking {
            return .checking
        }
        if stalledCount > 0 {
            return .stalled(count: stalledCount)
        }
        return .idle
    }

    public init() {}

    /// See `stagedActivity`. Only ever called from `-StageSyncStatus` handling.
    public func stage(_ activity: CloudKitSyncActivity) {
        stagedActivity = activity
    }

    /// Called only once a reconcile has decided it really will talk to CloudKit
    /// — a pass that short-circuits on the feature flag or the credential wait
    /// never reports, so it neither flashes the bar nor claims a sync.
    public func reportCheckStarted() {
        isChecking = true
    }

    public func reportCheckFinished() {
        isChecking = false
        lastSyncedAt = Date()
    }

    /// Progress within one upload drain pass.
    public func reportUploadProgress(completed: Int, total: Int) {
        uploadsCompleted = completed
        uploadsTotal = total
    }

    /// Ends an upload pass. `stalled` is the number of items that have given up
    /// and need the user to act (free up iCloud storage) before they move.
    public func reportUploadsFinished(stalled: Int) {
        uploadsCompleted = 0
        uploadsTotal = 0
        stalledCount = stalled
    }
}
