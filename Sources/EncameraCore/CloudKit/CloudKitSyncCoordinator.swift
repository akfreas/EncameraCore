//
//  CloudKitSyncCoordinator.swift
//  EncameraCore
//
//  Orchestrates CloudKit for one album: delta-syncs metadata into the existing
//  per-album MediaIndexStore, keeps an app-controlled evictable blob cache,
//  dedups concurrent blob fetches, applies cross-device deletes from the zone
//  change feed, and registers the zone push subscription. No app-UI wiring
//  (chunk 04+).
//  All CloudKit I/O goes through the chunk-02 `CloudKitMediaStoring` seam.
//

import Foundation

public extension Notification.Name {
    /// Posted (from the app delegate's silent-push handler, and on scene-active as
    /// the backstop) when the CloudKit zone may have changed. Observers trigger a
    /// `sync` on the active CloudKit album.
    static let cloudKitZoneChanged = Notification.Name("EncameraCloudKitZoneChanged")
}

/// One caller waiting on a shared blob download.
///
/// `@unchecked Sendable` because it is only ever read or mutated inside
/// `CloudKitSyncCoordinator`'s actor isolation; it crosses into the cancellation
/// handler as an opaque identity, never as shared mutable state.
private final class BlobWaiter: @unchecked Sendable {

    private enum State {
        /// Created, but the continuation hasn't been installed yet — the
        /// cancellation handler can land in this window.
        case pending
        case waiting(CheckedContinuation<URL, Error>)
        case done
    }

    /// This waiter's own progress sink. Every waiter gets its own, which is the
    /// whole point: a joiner used to inherit silence.
    let progress: @Sendable (Double) -> Void
    private var state: State = .pending

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    /// Installs the continuation. Returns false when the caller was already
    /// cancelled (in which case the continuation is resolved here), so the
    /// registration must be abandoned.
    func attach(_ continuation: CheckedContinuation<URL, Error>) -> Bool {
        switch state {
        case .pending:
            state = .waiting(continuation)
            return true
        case .waiting:
            // Unreachable: one continuation per waiter.
            return false
        case .done:
            continuation.resume(throwing: CancellationError())
            return false
        }
    }

    /// Resolves the waiter exactly once. Returns false when it was already
    /// resolved (or cancelled before it ever attached).
    @discardableResult
    func deliver(_ result: Result<URL, Error>) -> Bool {
        switch state {
        case .pending:
            // Cancelled before `attach` — mark it so registration bails out.
            state = .done
            return false
        case .waiting(let continuation):
            state = .done
            continuation.resume(with: result)
            return true
        case .done:
            return false
        }
    }
}

/// One shared `fetchBlob`, plus everyone waiting on it.
private final class BlobDownload {
    let id = UUID()
    var task: Task<Void, Never>?
    var waiters: [BlobWaiter] = []
    /// Highest fraction the fetch has reported, replayed to late joiners.
    var lastFraction: Double = 0
}

public actor CloudKitSyncCoordinator: DebugPrintable {

    private let albumID: String
    private let store: CloudKitMediaStoring
    private let cache: CloudKitBlobCache
    private let indexStore: MediaIndexStore
    private let bus: FileOperationBus
    /// Captures written to this device but not yet in CloudKit. Consulted before
    /// the cache on every read, so a just-taken photo opens immediately.
    private let uploadQueue: CloudKitUploadQueue

    /// In-flight blob fetches keyed by record name, so concurrent callers for the
    /// same record share one `fetchBlob` instead of issuing duplicates — while
    /// each keeps its own progress stream and its own right to walk away.
    private var downloads: [String: BlobDownload] = [:]
    /// Records known-deleted locally — a delete that lands mid-fetch wins. Purely a
    /// within-session race guard; the delete INTENT is durable and lives in
    /// `deleteQueue`.
    private var deletedRecordNames: Set<String> = []
    /// Latest server change tag per record, used to invalidate stale cache copies.
    private var changeTags: [String: String] = [:]
    /// Deletes the server has not confirmed, persisted so an intent formed offline
    /// or interrupted by termination is retried on a later sync.
    private let deleteQueue: CloudKitMediaDeleteQueue

    /// Drops every trace of a delete for `recordName`, because the record is live
    /// again. Both marks have to go together: `deletedRecordNames` alone would keep
    /// refusing to read the record, and a queued delete alone would still remove it.
    ///
    /// This is what makes a republished record name safe without asking the server
    /// whether it is live: an explicit upload of a name supersedes any delete still
    /// pending for it, and because the queue is process-wide the coordinator that
    /// republishes need not be the one that queued the delete.
    private func forgetDeletion(of recordName: String) {
        deletedRecordNames.remove(recordName)
        deleteQueue.remove(recordName)
    }

    /// Deletes the local encrypted preview for a media id.
    ///
    /// Only safe once the media's LAST component is gone: previews are keyed by
    /// media id in one storage-agnostic directory, so a Live Photo's photo and
    /// video components share a single file. Every caller gates on the
    /// `entryRemoved` result of the index removal for exactly that reason.
    private func removeLocalPreview(mediaID: String) {
        let previewURL = CloudKitStorageModel.previewURL(forMediaID: mediaID)
        guard FileManager.default.fileExists(atPath: previewURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: previewURL)
            printDebug("removeLocalPreview ok mediaID=\(mediaID)")
        } catch {
            // The blob is gone but its thumbnail bytes stay on disk — a silent
            // leak that grows with every cross-device delete.
            printDebug("removeLocalPreview FAILED mediaID=\(mediaID) file=\(previewURL.lastPathComponent) raw=\(error)")
        }
    }

    public init(albumID: String,
                store: CloudKitMediaStoring,
                cache: CloudKitBlobCache,
                indexStore: MediaIndexStore,
                bus: FileOperationBus = .shared,
                uploadQueue: CloudKitUploadQueue = .shared,
                deleteQueue: CloudKitMediaDeleteQueue = CloudKitMediaDeleteQueue()) {
        self.albumID = albumID
        self.store = store
        self.cache = cache
        self.indexStore = indexStore
        self.bus = bus
        self.uploadQueue = uploadQueue
        self.deleteQueue = deleteQueue
    }

    // MARK: - Sync

    /// The latest known server change tag for a record (so callers can detect a
    /// stale local copy after a remote re-upload).
    public func currentChangeTag(recordName: String) -> String? {
        changeTags[recordName]
    }

    private var activeSync: Task<Void, Error>?
    private var resyncRequested = false

    public func sync(albumID: String) async throws {
        // Single-flight that JOINS: a sync requested while one runs flags a re-run and
        // then awaits the active task (which loops to honor the request), so callers
        // never return before their changes are applied, yet overlapping calls coalesce
        // into at most one extra pass — no concurrent load–merge–save racing the index.
        if let active = activeSync {
            printDebug("sync join albumID=\(albumID) — a sync is already running; flagged a re-run and awaiting it")
            resyncRequested = true
            try await active.value
            return
        }
        let task = Task {
            // Clear the single-flight slot HERE, in the same synchronous stretch
            // as drainSync's final `resyncRequested` check (no suspension between
            // the check, the return, and this defer). A joiner therefore either
            // sees the task — and its flag is guaranteed to be honored by the
            // loop — or sees no task and starts a fresh sync. Clearing in the
            // caller instead left a window where a joiner's request could land
            // after the final check yet still join the finished task.
            defer { activeSync = nil }
            // Self-heal push registration on EVERY sync — a failed registration,
            // and also one the STORE invalidated after the fact (it clears its
            // persisted flag on `.zoneNotFound` when the zone is deleted in
            // iCloud Settings or the account is wiped). A coordinator-side
            // "already registered" bool went stale-true in that second case and
            // push-driven sync stayed silently dead for the life of the process.
            // The store's persisted-flag check makes the genuinely-registered
            // attempt a cheap no-op, so dedup lives there, not here.
            await startObserving()
            try await drainSync(albumID: albumID)
        }
        activeSync = task
        do {
            try await task.value
        } catch {
            printDebug("sync FAILED albumID=\(albumID) raw=\(error)")
            throw error
        }
    }

    private func drainSync(albumID: String) async throws {
        var pass = 0
        repeat {
            pass += 1
            resyncRequested = false
            do {
                try await performSync(albumID: albumID)
            } catch CloudKitMediaStoreError.changeTokenExpired {
                // The stored token is no longer valid: discard it and full-resync once.
                printDebug("drainSync token EXPIRED albumID=\(albumID) pass=\(pass) — resetting the change token and full-resyncing")
                await store.resetChangeToken()
                try await performSync(albumID: albumID)
            }
        } while resyncRequested
        printDebug("drainSync ok albumID=\(albumID) passes=\(pass)")
    }

    /// One component of a media item, identified the way the index identifies it
    /// (`indexEntry(from:)` derives the component flags from `mediaID` + `mediaType`).
    /// Comparing on this pair rather than on record names keeps the reap correct
    /// regardless of how a record name is spelled.
    private struct MediaComponent: Hashable {
        let mediaID: String
        let mediaType: MediaType
    }

    /// Drops index entries whose records a from-scratch fetch did not return.
    ///
    /// Without this, a delete this device never saw in the change feed is invisible
    /// forever: `performSync` only ever applies what the feed reports, so a record
    /// deleted while the token was expired (or before an index rebuild) keeps its
    /// index entry, its cached blob and its preview for the life of the install.
    ///
    /// Items still waiting in the upload queue are exempt. They are legitimately in
    /// the index and legitimately absent from the server — that is what "pending
    /// upload" means — and reaping them would delete a just-captured photo before
    /// its bytes ever left the device.
    private func reap(from entries: inout [MediaIndexEntry],
                      seen: Set<MediaComponent>,
                      pendingDeletes: inout [EncryptedMedia],
                      pendingCreates: inout [EncryptedMedia]) async {
        let pendingUpload = Set(await uploadQueue.all().map {
            MediaComponent(mediaID: $0.mediaID, mediaType: $0.mediaType)
        })
        var reaped = 0
        var exempt = 0

        for entry in entries {
            var components: [MediaComponent] = []
            if entry.hasPhotoComponent { components.append(.init(mediaID: entry.id, mediaType: .photo)) }
            if entry.hasVideoComponent { components.append(.init(mediaID: entry.id, mediaType: .video)) }

            for component in components where !seen.contains(component) {
                guard !pendingUpload.contains(component) else {
                    exempt += 1
                    printDebug("reap skip mediaID=\(component.mediaID) mediaType=\(component.mediaType) reason=pendingUpload")
                    continue
                }
                let recordName = MediaRecordName.componentRecordName(mediaID: component.mediaID,
                                                                     type: component.mediaType)
                let entryRemoved = entries.removeComponent(recordName: recordName)
                deletedRecordNames.insert(recordName)
                changeTags[recordName] = nil
                await cache.evict(recordName: recordName)
                if entryRemoved { removeLocalPreview(mediaID: component.mediaID) }
                let media = Self.media(forRecordName: component.mediaID,
                                       albumID: self.albumID,
                                       mediaType: component.mediaType)
                if entryRemoved { pendingDeletes.append(media) } else { pendingCreates.append(media) }
                reaped += 1
                printDebug("reap ok recordName=\(recordName) mediaID=\(component.mediaID) mediaType=\(component.mediaType) entryRemoved=\(entryRemoved) — absent from a full fetch")
            }
        }

        // Loud on purpose: a reap that fires on a healthy album means the full
        // fetch came back short, and this pass just deleted live media locally.
        printDebug("reap done albumID=\(self.albumID) reaped=\(reaped) exemptPendingUpload=\(exempt) seen=\(seen.count) entriesRemaining=\(entries.count)")
    }

    private func performSync(albumID: String) async throws {
        // Push unconfirmed deletes FIRST, so the fetch below sees a zone that
        // already reflects them. Whatever fails to drain is excluded from the
        // upsert path — otherwise its still-live remote record would resurrect the
        // item on the very device that deleted it.
        let undrainedDeletes = await drainPendingDeletes()

        // Diff from the authoritative on-disk index, refreshing the store's cache.
        let loaded = await indexStore.reloadFromDisk()
        var entries = loaded?.entries ?? []
        printDebug("performSync start albumID=\(albumID) coordinatorAlbumID=\(self.albumID) indexLoaded=\(loaded != nil) entries=\(entries.count) undrainedDeletes=\(undrainedDeletes.count)")

        // Buffer gallery events and emit them ONLY after the index is durably saved,
        // so a save failure + retry can't fire duplicate refreshes for unpersisted items.
        var pendingCreates: [EncryptedMedia] = []
        var pendingDeletes: [EncryptedMedia] = []

        // Drain the whole delta, not just the first page (the store advances its
        // persisted token each call, so passing nil continues from where it left off).
        var token = await store.loadChangeToken()

        // If the on-disk index is missing/corrupt but a token is still set (e.g. the
        // index was cleared), the token would skip every historical record and leave
        // the album empty forever — so discard it and resync from scratch.
        if loaded == nil, await store.hasChangeToken() {
            printDebug("performSync token DISCARDED albumID=\(self.albumID) — on-disk index is missing/corrupt while a token exists; resyncing from scratch")
            await store.resetChangeToken()
            token = nil
        }
        // A from-scratch fetch returns every live record in the zone, so anything
        // this album's index claims that does NOT come back no longer exists —
        // the only chance to notice a delete whose change-feed entry we missed
        // (an expired token, a cleared index). On an incremental fetch the feed
        // reports just the delta, so absence there means nothing at all.
        let startedWithoutToken = token == nil
        var seen: Set<MediaComponent> = []
        var snapshotComplete = false

        var moreComing = true
        var page = 0
        var skippedOtherAlbum = 0
        while moreComing {
            page += 1
            let changeSet: CloudKitChangeSet
            do {
                changeSet = try await store.fetchChanges(since: token)
            } catch {
                printDebug("performSync fetchChanges FAILED albumID=\(self.albumID) page=\(page) hadToken=\(token != nil) raw=\(error)")
                throw error
            }
            printDebug("performSync page ok albumID=\(self.albumID) page=\(page) changed=\(changeSet.changed.count) deleted=\(changeSet.deleted.count) moreComing=\(changeSet.moreComing) newToken=\(changeSet.token != nil)")
            if changeSet.token != nil { token = changeSet.token }   // advance the cursor across pages
            moreComing = changeSet.moreComing
            // The final page decides: an authoritative drain is one the server
            // acknowledged all the way to its end.
            snapshotComplete = changeSet.snapshotComplete

            for meta in changeSet.changed {
                // The zone is shared across albums; only apply records for THIS album.
                guard meta.albumID == self.albumID else {
                    skippedOtherAlbum += 1
                    continue
                }

                // A record whose delete has not reached the server yet still reads
                // as live. Pulling it in would resurrect, on the deleting device,
                // exactly the item the user removed.
                if undrainedDeletes.contains(meta.recordName) {
                    printDebug("performSync upsert skip recordName=\(meta.recordName) reason=deletePending")
                    continue
                }

                if let tag = meta.recordChangeTag { changeTags[meta.recordName] = tag }
                deletedRecordNames.remove(meta.recordName)
                seen.insert(MediaComponent(mediaID: meta.mediaID, mediaType: meta.mediaType))
                // The shared `upsert` appends a new item or merges a Live Photo's
                // second component into the existing entry, and reports whether the
                // index actually changed. Refresh the gallery only on a real change —
                // a no-op re-sync stays silent, so a large initial sync doesn't fire
                // hundreds of redundant reconciles.
                if entries.upsert(Self.indexEntry(from: meta)) {
                    pendingCreates.append(Self.media(forRecordName: meta.mediaID, albumID: self.albumID, mediaType: meta.mediaType))
                    printDebug("performSync upsert recordName=\(meta.recordName) mediaID=\(meta.mediaID) mediaType=\(meta.mediaType) sizeBytes=\(meta.sizeBytes) changeTag=\(meta.recordChangeTag ?? "nil")")
                } else {
                    // Distinguishes a genuine no-op re-sync from a dropped record:
                    // both look identical in the pendingCreates count otherwise.
                    printDebug("performSync upsert skip recordName=\(meta.recordName) — index already current, no gallery refresh emitted")
                }
            }

            for recordName in changeSet.deleted {
                let mediaID = MediaRecordName.mediaID(from: recordName)

                // Evict BEFORE the index-membership guard below. The record is gone
                // from the zone whichever album owned it, so dropping any cached
                // ciphertext is always correct — and a blob whose index entry
                // vanished by some other path would otherwise be stranded on disk
                // with nothing left to evict it. `evict` no-ops when not cached.
                await cache.evict(recordName: recordName)

                // The rest of the delete spans the whole shared zone; only act on
                // records this album actually holds (the deleted payload carries no
                // albumID). The owning album's coordinator does its own cleanup —
                // including the preview, which we cannot reason about here because
                // component survival is only knowable from that album's index.
                guard entries.contains(where: { $0.id == mediaID }) else {
                    printDebug("performSync hardDelete skip recordName=\(recordName) mediaID=\(mediaID) — not in this album's index (shared-zone delete for another album); cache evicted")
                    continue
                }

                // Clear only this component; keep the entry if the other survives.
                let entryRemoved = entries.removeComponent(recordName: recordName)
                deletedRecordNames.insert(recordName)
                changeTags[recordName] = nil
                if entryRemoved { removeLocalPreview(mediaID: mediaID) }
                // The deletion payload carries no fields, but the record name encodes
                // the component type — so a hard delete still emits a well-typed bus
                // event instead of the `.unknown` the gallery cannot act on.
                let mediaType = MediaRecordName.mediaType(from: recordName)
                let media = Self.media(forRecordName: mediaID, albumID: self.albumID, mediaType: mediaType)
                if entryRemoved { pendingDeletes.append(media) } else { pendingCreates.append(media) }
                printDebug("performSync hardDelete recordName=\(recordName) mediaID=\(mediaID) mediaType=\(mediaType) entryRemoved=\(entryRemoved)")
            }
        }
        if skippedOtherAlbum > 0 {
            printDebug("performSync skip albumID=\(self.albumID) otherAlbumRecords=\(skippedOtherAlbum) (shared zone)")
        }

        // Reap only when this pass was a from-scratch fetch the server acknowledged
        // to its end — the one case where the feed's answer is a COMPLETE snapshot
        // of the zone, so a record's absence from it means deletion. On an
        // incremental fetch absence means nothing, and on an unacknowledged one we
        // have no evidence the answer was whole; reaping on either would delete
        // live media locally.
        if startedWithoutToken, snapshotComplete {
            await reap(from: &entries,
                       seen: seen,
                       pendingDeletes: &pendingDeletes,
                       pendingCreates: &pendingCreates)
        } else if startedWithoutToken {
            printDebug("reap skip albumID=\(self.albumID) reason=snapshotNotAcknowledged — the full fetch returned no cursor, so absence cannot be read as deletion")
        }

        // Save the whole rebuilt index in ONE write before emitting or committing
        // the token, so a crash mid-sequence re-fetches rather than losing data.
        do {
            try await indexStore.replace(with: entries)
        } catch {
            // Nothing after this point runs: no gallery events, no token commit.
            // The next sync re-fetches the same delta from the un-advanced token.
            printDebug("performSync indexSave FAILED albumID=\(self.albumID) entries=\(entries.count) pendingCreates=\(pendingCreates.count) pendingDeletes=\(pendingDeletes.count) raw=\(error)")
            throw error
        }

        // The index is durably saved — now it is safe to notify the gallery.
        for media in pendingCreates { bus.didCreate(media) }
        if !pendingDeletes.isEmpty { bus.didDelete(pendingDeletes) }
        printDebug("performSync applied albumID=\(self.albumID) entries=\(entries.count) creates=\(pendingCreates.count) deletes=\(pendingDeletes.count) pages=\(page)")

        // Commit the change token ONLY after the index is durably saved. If the save
        // above threw, the token is not advanced and the next sync re-fetches.
        await store.commitChangeToken(token)
        if token == nil {
            // No token to commit means the next sync refetches the whole zone —
            // fine once, pathological if it repeats every pass.
            printDebug("performSync token WARNING albumID=\(self.albumID) — no token returned by the change feed; next sync will full-fetch")
        }

    }

    /// Retries deletes the server has not confirmed, and reports what is still
    /// outstanding so the caller can refuse to re-materialize those records.
    ///
    /// Runs BEFORE the change feed is read: a delete that lands here is reflected
    /// in the very fetch that follows, instead of the record arriving as a live
    /// change and being pulled straight back into the index.
    ///
    /// A record that is genuinely gone drains on `.notFound` — deleting is
    /// idempotent, so this needs no "is it still there?" round-trip. Only
    /// transient failures stay queued.
    private func drainPendingDeletes() async -> Set<String> {
        var outstanding = deleteQueue.pending()
        guard !outstanding.isEmpty else { return [] }
        printDebug("drainPendingDeletes start albumID=\(self.albumID) pending=\(outstanding.count)")

        for recordName in outstanding.sorted() {
            do {
                try await store.delete(recordName: recordName)
                deleteQueue.remove(recordName)
                outstanding.remove(recordName)
                printDebug("drainPendingDeletes ok recordName=\(recordName)")
            } catch CloudKitMediaStoreError.notFound {
                deleteQueue.remove(recordName)
                outstanding.remove(recordName)
                printDebug("drainPendingDeletes skip recordName=\(recordName) — already gone from the zone")
            } catch {
                // Stays queued; log so a permanently stuck delete (which also
                // suppresses that record's re-materialization) is visible.
                printDebug("drainPendingDeletes FAILED recordName=\(recordName) — left queued raw=\(error)")
            }
        }
        printDebug("drainPendingDeletes done albumID=\(self.albumID) stillPending=\(outstanding.count)")
        return outstanding
    }

    // MARK: - Blob residency

    /// Downloads the record's ciphertext into the blob cache, or returns the copy
    /// already there.
    ///
    /// Callers for the same record share ONE fetch, and every one of them is a
    /// first-class waiter: each gets its own progress stream (a late joiner is
    /// first replayed the fraction the download has already reached), and each can
    /// walk away independently. The fetch is cancelled only when the LAST waiter
    /// goes away.
    ///
    /// Both halves of that matter — together they are the reported "cancel a
    /// download, start it again, watch it freeze" bug. This used to
    /// await the shared `Task.value` directly, which:
    ///   - ignored the *caller's* cancellation — awaiting an unstructured task is
    ///     not a cancellation point, so tapping Cancel neither stopped the download
    ///     nor released the caller; and
    ///   - fed progress only to the closure of whoever started the fetch, so the
    ///     retry after a cancel joined a download it could not hear, and its
    ///     progress bar sat frozen at whatever it last displayed until the whole
    ///     (in the report: 552 MB) transfer finished.
    public func ensureBlobLocal(recordName: String,
                                albumID: String,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if deletedRecordNames.contains(recordName) {
            printDebug("ensureBlobLocal FAILED recordName=\(recordName) reason=knownDeletedLocally")
            throw CloudKitMediaStoreError.notFound
        }

        // Before anything else: a capture that has not uploaded yet exists ONLY
        // in the holding folder. It is absent from the cache and absent from
        // CloudKit, so without this the read would go to the network and come
        // back "record not found" for a photo sitting on the device.
        if let waiting = await uploadQueue.pendingFileURL(recordName: recordName) {
            printDebug("ensureBlobLocal hit recordName=\(recordName) source=uploadQueue file=\(waiting.lastPathComponent)")
            progress(1.0)
            return waiting
        }

        let expectedTag = changeTags[recordName]
        if let cached = await cache.cachedURL(recordName: recordName, changeTag: expectedTag) {
            printDebug("ensureBlobLocal hit recordName=\(recordName) source=cache expectedTag=\(expectedTag ?? "nil") file=\(cached.lastPathComponent)")
            progress(1.0)
            return cached
        }
        try Task.checkCancellation()

        let waiter = BlobWaiter(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                register(waiter: waiter,
                         continuation: continuation,
                         recordName: recordName,
                         albumID: albumID,
                         expectedTag: expectedTag)
            }
        } onCancel: {
            // The handler runs off the actor, so hop back on to unregister. It can
            // beat `register` — `BlobWaiter.state` is what makes that race safe.
            Task { await self.cancel(waiter: waiter, recordName: recordName) }
        }
    }

    /// Attaches `waiter` to the record's download, starting one if this is the
    /// first interested caller. Runs on the actor, synchronously, from inside the
    /// continuation body.
    private func register(waiter: BlobWaiter,
                          continuation: CheckedContinuation<URL, Error>,
                          recordName: String,
                          albumID: String,
                          expectedTag: String?) {
        guard waiter.attach(continuation) else {
            // Cancelled while we were getting here.
            return
        }
        let download: BlobDownload
        if let existing = downloads[recordName] {
            download = existing
            printDebug("ensureBlobLocal join recordName=\(recordName) waiters=\(existing.waiters.count + 1) atFraction=\(existing.lastFraction) — an identical fetch is already in flight")
        } else {
            download = BlobDownload()
            downloads[recordName] = download
            printDebug("ensureBlobLocal MISS recordName=\(recordName) albumID=\(albumID) expectedTag=\(expectedTag ?? "nil") — downloading from CloudKit")
            download.task = fetchTask(downloadID: download.id,
                                      recordName: recordName,
                                      albumID: albumID,
                                      expectedTag: expectedTag)
        }
        download.waiters.append(waiter)
        // Replay where the download actually is, so a joiner's UI starts there
        // instead of sitting at 0% until the next tick.
        if download.lastFraction > 0 {
            waiter.progress(download.lastFraction)
        }
    }

    /// Drives one shared fetch. Reports progress and its result back onto the
    /// actor, which fans both out to the download's waiters.
    private func fetchTask(downloadID: UUID,
                           recordName: String,
                           albumID: String,
                           expectedTag: String?) -> Task<Void, Never> {
        let store = self.store
        let cache = self.cache
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckdl-\(recordName)-\(UUID().uuidString)")

        return Task { [weak self] in
            let result: Result<URL, Error>
            do {
                try await store.fetchBlob(recordName: recordName, to: destination) { fraction in
                    Task { await self?.report(fraction: fraction, recordName: recordName, downloadID: downloadID) }
                }
                let cachedURL = try await cache.store(recordName: recordName,
                                                      changeTag: expectedTag,
                                                      albumID: albumID,
                                                      from: destination)
                result = .success(cachedURL)
            } catch {
                result = .failure(error)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch {
                    // Non-fatal: the blob is already cached. But a leaked temp file per
                    // download adds up, so it should be visible.
                    Self.printDebug("ensureBlobLocal WARNING recordName=\(recordName) could not remove download temp file=\(destination.lastPathComponent) raw=\(error)")
                }
            }
            await self?.finish(downloadID: downloadID, recordName: recordName, result: result)
        }
    }

    /// Fans a progress tick out to every waiter on the download.
    private func report(fraction: Double, recordName: String, downloadID: UUID) {
        guard let download = downloads[recordName], download.id == downloadID else { return }
        // Never go backwards: CloudKit can repeat a fraction, and a joiner that was
        // just replayed the current position must not see the bar jump back.
        guard fraction > download.lastFraction else { return }
        download.lastFraction = fraction
        for waiter in download.waiters {
            waiter.progress(fraction)
        }
    }

    /// Resolves every waiter on the download and retires it.
    private func finish(downloadID: UUID, recordName: String, result: Result<URL, Error>) async {
        guard let download = downloads[recordName], download.id == downloadID else {
            // Superseded: every waiter walked away (the fetch was cancelled) or a
            // newer download replaced this one. Nothing left to notify.
            return
        }
        downloads[recordName] = nil

        switch result {
        case .success(let url):
            // A delete that landed mid-fetch wins: discard the fetched copy.
            if deletedRecordNames.contains(recordName) {
                printDebug("ensureBlobLocal FAILED recordName=\(recordName) reason=deletedDuringFetch — evicting the just-fetched copy")
                await cache.evict(recordName: recordName)
                download.waiters.forEach { $0.deliver(.failure(CloudKitMediaStoreError.notFound)) }
                return
            }
            printDebug("ensureBlobLocal ok recordName=\(recordName) source=network waiters=\(download.waiters.count) file=\(url.lastPathComponent)")
            for waiter in download.waiters {
                waiter.progress(1.0)
                waiter.deliver(.success(url))
            }
        case .failure(let error):
            printDebug("ensureBlobLocal FAILED recordName=\(recordName) albumID=\(albumID) waiters=\(download.waiters.count) raw=\(error)")
            download.waiters.forEach { $0.deliver(.failure(error)) }
        }
    }

    /// Releases one waiter. The shared fetch is stopped only once nobody is left
    /// waiting on it, so one view walking away never strands another.
    private func cancel(waiter: BlobWaiter, recordName: String) {
        guard waiter.deliver(.failure(CancellationError())) else { return }
        guard let download = downloads[recordName],
              download.waiters.contains(where: { $0 === waiter }) else { return }
        download.waiters.removeAll { $0 === waiter }
        guard download.waiters.isEmpty else {
            printDebug("ensureBlobLocal waiter cancelled recordName=\(recordName) remainingWaiters=\(download.waiters.count) — download continues")
            return
        }
        printDebug("ensureBlobLocal cancelled recordName=\(recordName) — last waiter went away; cancelling the CloudKit fetch")
        downloads[recordName] = nil
        download.task?.cancel()
    }

    // MARK: - Upload

    /// Puts a capture into the local index and announces it, without touching
    /// CloudKit — the photo becomes visible in the album straight away and the
    /// upload follows behind it (`CloudKitUploader`).
    ///
    /// Split out of `upload` deliberately: while CloudKit gated this step, a
    /// refused record meant the capture never entered the index and was lost
    /// even though its ciphertext was already on disk.
    public func registerLocally(_ item: CloudKitMediaUpload) async throws {
        do {
            try await indexStore.upsert([Self.indexEntry(fromUpload: item)])
        } catch {
            printDebug("registerLocally indexUpsert FAILED recordName=\(item.recordName) mediaID=\(item.mediaID) raw=\(error)")
            throw error
        }
        bus.didCreate(Self.media(forRecordName: item.mediaID, albumID: item.albumID, mediaType: item.mediaType))
        printDebug("registerLocally ok recordName=\(item.recordName) mediaID=\(item.mediaID)")
    }

    /// - Parameter alreadyVisibleLocally: true when `registerLocally` has already
    ///   indexed and announced this item (the capture path). The index upsert
    ///   still runs — it is idempotent, and the migration path relies on it — but
    ///   the gallery is not told twice about the same photo.
    public func upload(_ item: CloudKitMediaUpload,
                       progress: @escaping @Sendable (Double) -> Void,
                       alreadyVisibleLocally: Bool = false) async throws -> CloudKitMediaRef {
        printDebug("upload start recordName=\(item.recordName) albumID=\(item.albumID) mediaType=\(item.mediaType) sizeBytes=\(item.sizeBytes)")
        // Issuing this upload is a deliberate (re)publication of the record name, so
        // any delete bookkeeping from BEFORE it started is stale. The case that
        // matters: moving an album out of iCloud calls `remove` for every item,
        // leaving each one marked deleted-locally and queued for a hard purge — all
        // in memory, on a coordinator the registry hands straight back when the album
        // is moved to iCloud again. Without this, the guard after the store call
        // fires on the very record the user asked to upload, marks it deleted, and the
        // stale purge then deletes their photo from iCloud.
        //
        // Clearing here (before the `await`, on the actor) is also what makes that
        // guard mean what it says: a delete that landed *during* this upload. One
        // arriving now re-inserts the marks and still wins.
        forgetDeletion(of: item.recordName)
        let ref: CloudKitMediaRef
        do {
            do {
                ref = try await store.upload(item, progress: progress)
            } catch CloudKitMediaStoreError.zoneNotFound {
                // The zone was removed server-side (cleared iCloud data) while our
                // local flag said it existed. Recreate it and retry once — the
                // behaviour the old synchronous save path had; without it a queued
                // capture retries against a nonexistent zone forever.
                printDebug("upload zoneNotFound recordName=\(item.recordName) — recreating the zone and retrying once")
                try await store.recreateZone()
                ref = try await store.upload(item, progress: progress)
            }
        } catch {
            printDebug("upload FAILED recordName=\(item.recordName) albumID=\(item.albumID) raw=\(error)")
            throw error
        }

        // A delete that raced this upload wins: the user removed the item while
        // its bytes were in flight, so the record that just landed must not be
        // indexed, cached, or announced — and the server copy is reclaimed.
        // Without this check the success path below would re-upsert the entry and
        // clear the deletion marker, resurrecting a deleted photo locally AND on
        // every other device.
        if deletedRecordNames.contains(item.recordName) {
            printDebug("upload landed after delete recordName=\(item.recordName) — deleting the fresh record and discarding the result")
            // Queue first, so the reclaim survives a failure here or a kill before
            // the delete lands. Retried by the next sync's drain.
            deleteQueue.enqueue(item.recordName)
            do {
                try await store.delete(recordName: item.recordName)
                deleteQueue.remove(item.recordName)
            } catch {
                printDebug("upload postDeleteReclaim FAILED recordName=\(item.recordName) — left queued raw=\(error)")
            }
            throw CloudKitMediaStoreError.cancelled
        }

        if let tag = ref.recordChangeTag { changeTags[ref.recordName] = tag }
        deletedRecordNames.remove(ref.recordName)
        // Cache the just-uploaded encrypted file (the authoring device keeps its copy).
        do {
            try await cache.store(recordName: ref.recordName,
                                  changeTag: ref.recordChangeTag,
                                  albumID: item.albumID,
                                  from: item.encryptedFileURL)
        } catch {
            // Swallowed on purpose (the upload itself succeeded), but it means the
            // authoring device will re-download its own freshly uploaded blob.
            printDebug("upload WARNING recordName=\(ref.recordName) local cache store failed; blob will be re-downloaded on next read raw=\(error)")
        }

        // Upsert (through the store's cache) merges a Live Photo's photo and video
        // components into one entry; the store persists and caches in one step.
        do {
            try await indexStore.upsert([Self.indexEntry(fromUpload: item)])
        } catch {
            printDebug("upload indexUpsert FAILED recordName=\(ref.recordName) mediaID=\(item.mediaID) — record is in CloudKit but not in the local index raw=\(error)")
            throw error
        }
        printDebug("upload ok recordName=\(ref.recordName) changeTag=\(ref.recordChangeTag ?? "nil")")
        if !alreadyVisibleLocally {
            // Surface the new item on the same bus the gallery already listens to.
            bus.didCreate(Self.media(forRecordName: item.mediaID, albumID: item.albumID, mediaType: item.mediaType))
        }
        return ref
    }

    // MARK: - Delete

    /// Deletes the record outright, then clears local state.
    ///
    /// The intent is queued durably BEFORE the delete is issued, so the delete is
    /// not lost to being offline or to termination mid-flight — the next sync
    /// drains the queue. That durability is also why a failed delete no longer
    /// aborts the local cleanup: the item leaves this device immediately and the
    /// server copy is reclaimed on a later pass, instead of the user's delete
    /// appearing to do nothing. Until the queue drains, `performSync` refuses to
    /// re-materialize the record from its still-live remote copy.
    ///
    /// - Parameter wasPending: true when the item was still in the upload queue,
    ///   i.e. it (almost certainly) never reached CloudKit, so there is nothing to
    ///   delete remotely. "Almost": an upload may land while this delete runs, so
    ///   the record is still marked in `deletedRecordNames`, which `upload` checks
    ///   after its store call.
    public func remove(recordName: String, albumID: String, wasPending: Bool = false) async throws {
        printDebug("remove start recordName=\(recordName) albumID=\(albumID) wasPending=\(wasPending)")
        deletedRecordNames.insert(recordName)
        changeTags[recordName] = nil
        await cache.evict(recordName: recordName)

        if !wasPending {
            // Enqueue BEFORE the call: a delete that never gets issued (offline, or
            // the process dies here) must still be retried, and the queue is what
            // keeps the record from being pulled back in meanwhile.
            deleteQueue.enqueue(recordName)
            do {
                try await store.delete(recordName: recordName)
                deleteQueue.remove(recordName)
                printDebug("remove delete ok recordName=\(recordName)")
            } catch CloudKitMediaStoreError.notFound {
                // Already absent — deleted from another device, or never uploaded.
                // Nothing to delete is success for a delete.
                deleteQueue.remove(recordName)
                printDebug("remove delete skip recordName=\(recordName) — record already absent from the zone")
            } catch {
                // Left queued on purpose. The local cleanup below still runs.
                printDebug("remove delete FAILED recordName=\(recordName) albumID=\(albumID) — left queued for the next sync raw=\(error)")
            }
        }

        // Clear only this component; the entry survives if the other component does.
        // The store persists and caches; a no-op (record already absent) skips the write.
        let entryRemoved: Bool
        do {
            entryRemoved = try await indexStore.removeComponent(recordName: recordName)
        } catch {
            // The record is gone (or queued to go) server-side, so a failure here
            // leaves the local index claiming an item that no longer exists remotely.
            printDebug("remove indexRemove FAILED recordName=\(recordName) — record is deleted in CloudKit but still in the local index raw=\(error)")
            throw error
        }
        if entryRemoved { removeLocalPreview(mediaID: MediaRecordName.mediaID(from: recordName)) }
        printDebug("remove ok recordName=\(recordName) entryRemoved=\(entryRemoved) stillQueued=\(deleteQueue.pending().count)")

        emitDeletion(mediaID: MediaRecordName.mediaID(from: recordName), entryRemoved: entryRemoved)
    }

    /// Emit a delete when the whole item is gone, otherwise a refresh so the
    /// gallery re-reads the still-present item rather than dropping it.
    private func emitDeletion(mediaID: String, entryRemoved: Bool) {
        let media = Self.media(forRecordName: mediaID, albumID: self.albumID, mediaType: .unknown)
        if entryRemoved {
            bus.didDelete([media])
        } else {
            bus.didCreate(media)
        }
    }

    /// Whether the record's ciphertext is resident in the blob cache right now.
    /// Used by the flight check to assert that a cancelled download really stopped
    /// — a timing-free statement of it, unlike watching the clock on a fast link.
    public func isBlobCached(recordName: String) async -> Bool {
        await cache.cachedURL(recordName: recordName, changeTag: changeTags[recordName]) != nil
    }

    public func evict(recordName: String) async throws {
        printDebug("evict start recordName=\(recordName) albumID=\(albumID)")
        await cache.evict(recordName: recordName)
    }

    public func evictAll(olderThan date: Date) async throws {
        printDebug("evictAll start albumID=\(albumID) olderThan=\(date)")
        await cache.evictAll(olderThan: date)
    }

    // MARK: - Push

    public func startObserving() async {
        guard await store.accountAvailable() else {
            printDebug("startObserving skip albumID=\(albumID) reason=accountUnavailable — no push subscription registered")
            return
        }   // skip when no account
        do {
            try await store.registerZoneSubscription()
            printDebug("startObserving ok albumID=\(albumID) zone subscription registered")
        } catch {
            printDebug("startObserving FAILED albumID=\(albumID) zone subscription not registered; push-driven sync is off until the next sync retries raw=\(error)")
        }
    }

    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        printDebug("handleRemoteNotification start albumID=\(albumID) userInfoKeys=\(userInfo.keys.count)")
        do {
            try await sync(albumID: albumID)
            printDebug("handleRemoteNotification ok albumID=\(albumID)")
        } catch {
            // Swallowed by the original `try?`: a push-triggered sync failure was
            // completely invisible, so the album silently stays stale.
            printDebug("handleRemoteNotification FAILED albumID=\(albumID) raw=\(error)")
        }
    }

    // MARK: - Mapping helpers

    /// Maps one CloudKit component record to a single-component index entry.
    /// Source-specific (CloudKit -> entry), so it stays here rather than on the
    /// shared algebra — but it feeds the shared `upsert`. `internal` for the
    /// disk/cloud index-equivalence test.
    static func indexEntry(from meta: CloudKitMediaMetadata) -> MediaIndexEntry {
        // `createdAt` is the record's capture/encryption date — use it for BOTH so the
        // default encrypted-date gallery sort orders synced items by time, not last.
        MediaIndexEntry(id: meta.mediaID,
                        hasPhotoComponent: meta.mediaType == .photo,
                        hasVideoComponent: meta.mediaType == .video,
                        dateEncrypted: meta.createdAt,
                        dateTaken: meta.createdAt,
                        subtypeRawValue: 0)
    }

    private static func indexEntry(fromUpload item: CloudKitMediaUpload) -> MediaIndexEntry {
        // Use the capture date for BOTH dates so a freshly uploaded item sorts
        // consistently with the same item once it comes back through delta sync.
        MediaIndexEntry(id: item.mediaID,
                        hasPhotoComponent: item.mediaType == .photo,
                        hasVideoComponent: item.mediaType == .video,
                        dateEncrypted: item.createdAt,
                        dateTaken: item.createdAt,
                        subtypeRawValue: 0)
    }

    /// A lightweight `EncryptedMedia` carrying just the id/type so the gallery can
    /// react through the same `FileOperationBus` it uses for local file ops. The
    /// URL is synthetic — consumers key on `id`.
    private static func media(forRecordName recordName: String,
                              albumID: String,
                              mediaType: MediaType) -> EncryptedMedia {
        let url = URL(fileURLWithPath: "/cloudkit/\(albumID)/\(recordName)")
        return EncryptedMedia(source: url, mediaType: mediaType, id: recordName)
    }
}
