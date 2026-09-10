//
//  CloudKitUploader.swift
//  EncameraCore
//
//  Takes captures from `CloudKitUploadQueue` to CloudKit, in the background,
//  retrying until they land.
//
//  The capture path no longer waits on CloudKit: `CloudKitFileAccess.saveSingle`
//  writes the photo to the device, puts it in the album, and hands it here. That
//  makes an upload failure a delay rather than a loss — which is the whole point,
//  because the previous arrangement (upload first, record locally only on
//  success) silently discarded a capture whenever CloudKit refused a record.
//
//  A queued item can only be uploaded through its album's coordinator, and
//  building one needs the album key the queue deliberately does not store. So the
//  uploader works with the coordinators that already exist for albums opened this
//  launch; anything else drains when its album is next opened.
//

import Foundation
import UIKit

public actor CloudKitUploader: DebugPrintable {

    public static let shared = CloudKitUploader()

    private let queue: CloudKitUploadQueue
    private let registry: CloudKitCoordinatorRegistry

    private var drainTask: Task<Void, Never>?
    /// Set when work arrives while a drain is running, so the running pass loops
    /// again instead of the new item waiting for an unrelated trigger.
    private var moreWorkArrived = false

    /// Earliest next attempt per record, so a retryable failure is not retried in
    /// a tight loop. In memory only: after a relaunch everything is eligible
    /// again, which is the behaviour we want on a fresh start.
    private var nextAttemptAfter: [String: Date] = [:]
    private var hasSwept = false

    public init(queue: CloudKitUploadQueue = .shared,
                registry: CloudKitCoordinatorRegistry = .shared) {
        self.queue = queue
        self.registry = registry
    }

    // MARK: - Triggering

    /// Ask the uploader to make progress. Safe to call often and from anywhere —
    /// launch, foreground, a new capture, an album opening. Returns immediately;
    /// the work happens in the background.
    public func kick() {
        guard drainTask == nil else {
            moreWorkArrived = true
            return
        }
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.runDrain()
        }
    }

    /// Drains and waits for the pass to finish. For tests and for callers that
    /// need to know the queue was given a real chance to empty.
    public func drainNow() async {
        kick()
        await drainTask?.value
    }

    /// Cancels the drain task and prevents new kicks from starting. Called
    /// during erase so no uploads race the zone delete.
    public func shutdown() {
        drainTask?.cancel()
        drainTask = nil
        rekickTask?.cancel()
        rekickTask = nil
        printDebug("shutdown ok")
    }

    private func runDrain() async {
        let backgroundTask = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "CloudKitUploadDrain") { [weak self] in
                guard let self else { return }
                Task { await self.handleBackgroundExpiration() }
            }
        }
        defer {
            if backgroundTask != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(backgroundTask) }
            }
            drainTask = nil
            scheduleRekickIfNeeded()
        }
        repeat {
            moreWorkArrived = false
            await onePass()
        } while moreWorkArrived && !Task.isCancelled
    }

    private func handleBackgroundExpiration() {
        printDebug("background time expired, cancelling drain")
        drainTask?.cancel()
    }

    /// Wakes the drain when the earliest in-flight backoff expires. Replaced on
    /// every drain, so at most one timer exists.
    private var rekickTask: Task<Void, Never>?

    private func scheduleRekickIfNeeded() {
        rekickTask?.cancel()
        rekickTask = nil
        let now = Date()
        guard let earliest = nextAttemptAfter.values.filter({ $0 > now }).min() else { return }
        let delay = earliest.timeIntervalSince(now)
        rekickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    // MARK: - Draining

    private func onePass() async {
        // Once per launch, not per pass: reconciling the folder against the
        // manifest is startup housekeeping, and running it repeatedly only widens
        // the window where it can interact with an upload in flight.
        if !hasSwept {
            hasSwept = true
            await queue.sweep()
            // One fresh chance per launch for items that gave up (iCloud full):
            // the user may have freed space since. Mirrors `nextAttemptAfter`
            // being in-memory — a new launch starts clean — and is bounded to one
            // attempt per item per launch, so a still-full account costs a single
            // refused upload each, not a loop.
            await queue.retryGivenUp()
        }
        let items = await queue.all().filter { !$0.hasGivenUp }
        guard !items.isEmpty else {
            await reportPassFinished()
            return
        }

        printDebug("drain start pending=\(items.count)")
        var uploaded = 0
        var deferredCount = 0

        for item in items {
            guard !Task.isCancelled else {
                printDebug("drain cancelled, stopping between items")
                break
            }
            await CloudKitSyncStatusReporter.shared.reportUploadProgress(completed: uploaded,
                                                                        total: items.count)
            if let notBefore = nextAttemptAfter[item.recordName], notBefore > Date() {
                deferredCount += 1
                continue
            }
            guard let coordinator = await registry.existingCoordinator(forAlbumID: item.albumID) else {
                // Not openable from here — see the file header.
                deferredCount += 1
                continue
            }
            if await send(item, using: coordinator) { uploaded += 1 } else { deferredCount += 1 }
        }
        await reportPassFinished()
        printDebug("drain done uploaded=\(uploaded) deferred=\(deferredCount)")
    }

    /// Hands the UI the end of a pass: no upload is in flight, and whatever has
    /// given up is now the standing state. Reported even for an empty pass, so a
    /// backlog that drains — or one whose items are freed by `retryFailed` —
    /// clears the status bar rather than leaving a stale count on screen.
    private func reportPassFinished() async {
        let stalled = await queue.givenUp().count
        await CloudKitSyncStatusReporter.shared.reportUploadsFinished(stalled: stalled)
    }

    /// Returns true when the item reached CloudKit.
    private func send(_ item: CloudKitPendingUpload, using coordinator: CloudKitSyncCoordinator) async -> Bool {
        // The preview lives in the shared thumbnail directory, not the holding
        // folder, so it is resolved fresh at upload time. A missing one is not
        // fatal: the record simply uploads without an eager thumbnail.
        let previewURL = CloudKitStorageModel.previewURL(forMediaID: item.mediaID)
        let thumbURL = FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : nil
        let upload = await queue.rebuild(item, thumbURL: thumbURL)

        do {
            _ = try await coordinator.upload(upload, progress: { _ in }, alreadyVisibleLocally: true)
        } catch {
            await classify(error, for: item)
            return false
        }

        // Only now is it safe to drop the durable copy: `coordinator.upload` has
        // both put the bytes in CloudKit and stored them in the blob cache.
        await queue.complete(recordName: item.recordName)
        nextAttemptAfter[item.recordName] = nil
        return true
    }

    /// Decides whether an error is worth trying again. Getting this wrong in the
    /// permanent direction strands a photo; getting it wrong in the retryable
    /// direction just means pointless attempts — so anything unrecognised is
    /// treated as retryable.
    private func classify(_ error: Error, for item: CloudKitPendingUpload) async {
        switch mapCKError(error) {
        case .quotaExceeded:
            await queue.giveUp(recordName: item.recordName, reason: error)
            nextAttemptAfter[item.recordName] = nil
        case .accountUnavailable:
            // NOT a give-up: signed-out is transient (re-auth, account switch),
            // and `hasGivenUp` is persisted — items marked that way used to stay
            // stranded even after the user signed back in. Defer instead; the
            // `.CKAccountChanged` observer calls `retryFailed()`, which clears
            // these backoffs the moment the account returns.
            await queue.recordAttempt(recordName: item.recordName, error: error)
            nextAttemptAfter[item.recordName] = Date().addingTimeInterval(300)
        case .retry(let after):
            await queue.recordAttempt(recordName: item.recordName, error: error)
            nextAttemptAfter[item.recordName] = Date().addingTimeInterval(after)
        default:
            await queue.recordAttempt(recordName: item.recordName, error: error)
            // Back off further the more an item has failed, so a persistently
            // broken record cannot monopolise every pass. Capped so a transient
            // problem still recovers within a session.
            let attempts = min((await queue.all().first { $0.recordName == item.recordName })?.attempts ?? 1, 6)
            nextAttemptAfter[item.recordName] = Date().addingTimeInterval(pow(2, Double(attempts)))
        }
    }

    // MARK: - Recovery

    /// Give previously-abandoned items another go — after the user frees up
    /// iCloud storage or signs back in. Clears the give-up flag and drains.
    public func retryFailed() async {
        await queue.retryGivenUp()
        nextAttemptAfter.removeAll()
        kick()
    }
}
