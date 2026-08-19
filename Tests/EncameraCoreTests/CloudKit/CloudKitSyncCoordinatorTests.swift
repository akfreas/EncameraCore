//
//  CloudKitSyncCoordinatorTests.swift
//  EncameraCoreTests
//
//  Chunk 03 — coordinator + evictable cache, exercised against the mock store.
//

import XCTest
import Combine
@testable import EncameraCore

final class CloudKitSyncCoordinatorTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        for suite in deleteQueueSuites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        deleteQueueSuites = []
    }

    // MARK: - Builders

    private func makeIndexStore() -> MediaIndexStore {
        let url = tempRoot.appendingPathComponent("\(UUID().uuidString).encindex")
        return MediaIndexStore(keyBytes: Array(repeating: 7, count: 32), indexURL: url)
    }

    private func makeCache() -> CloudKitBlobCache {
        CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache-\(UUID().uuidString)"),
                          maxBytes: 500 * 1024 * 1024)
    }

    private func makeCoordinator(store: MockCloudKitMediaStore,
                                 bus: FileOperationBus = FileOperationBus(),
                                 deleteQueue: CloudKitMediaDeleteQueue? = nil)
        -> (CloudKitSyncCoordinator, MediaIndexStore, CloudKitBlobCache) {
        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: bus, deleteQueue: deleteQueue ?? makeDeleteQueue())
        return (coord, index, cache)
    }

    /// The delete queue is durable and process-wide, so tests must not share one:
    /// an entry left behind by one test would suppress another's upserts and issue
    /// phantom deletes. Each gets its own defaults suite, removed in teardown.
    private var deleteQueueSuites: [String] = []

    private func makeDeleteQueue() -> CloudKitMediaDeleteQueue {
        let suite = "ck-delete-\(UUID().uuidString)"
        deleteQueueSuites.append(suite)
        return CloudKitMediaDeleteQueue(defaults: UserDefaults(suiteName: suite)!)
    }

    private func meta(_ name: String,
                      type: MediaType = .photo,
                      tag: String? = "tag-1",
                      deletedAt: Date? = nil) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: name,
                              albumID: "a1",
                              mediaID: name,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: 10,
                              creationDeviceID: "device",
                              deletedAt: deletedAt,
                              schemaVersion: 1,
                              recordChangeTag: tag)
    }

    /// A single component of a media item (Live Photos share a mediaID across two records).
    private func metaComponent(recordName: String, mediaID: String, type: MediaType) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: recordName,
                              albumID: "a1",
                              mediaID: mediaID,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: 10,
                              creationDeviceID: "device",
                              deletedAt: nil,
                              schemaVersion: 1,
                              recordChangeTag: "tag-\(recordName)")
    }

    private func ids(_ store: MediaIndexStore) async -> [String] {
        (await store.load()?.entries ?? []).map { $0.id }.sorted()
    }

    /// Collects every fraction a caller's progress closure was handed.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Double] = []

        var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }

        var record: @Sendable (Double) -> Void {
            { [self] fraction in
                lock.lock(); _values.append(fraction); lock.unlock()
            }
        }
    }

    private struct TestTimeout: Error {}

    /// Fails fast instead of hanging the suite: every download assertion here is
    /// about a caller being released, so a wedged `await` is the failure.
    private func withTimeout<T: Sendable>(seconds: Double,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TestTimeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: - Sync reconciliation

    func testSyncUpsertsChangedRecordsIntoIndex() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        try await coord.sync(albumID: "a1")

        let result = await ids(index)
        XCTAssertEqual(result, ["m1", "m2"])
    }

    func testSyncRemovesDeletedRecordsAndEvicts() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["m1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let result = await ids(index)
        XCTAssertTrue(result.isEmpty)
    }

    func testSyncThrowsAndLeavesIndexUnchangedOnError() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.fetchChangesError = CKErrorFactory.error(.networkUnavailable)
        do {
            try await coord.sync(albumID: "a1")
            XCTFail("Expected throw")
        } catch {
            // expected
        }
        let result = await ids(index)
        XCTAssertEqual(result, ["m1"], "A failed sync must not mutate the index")
    }

    // MARK: - Blob residency

    func testEnsureBlobLocalCachesOnMissAndHitsCacheOnSecondCall() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        let url1 = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)

        let url2 = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1, "Second call must hit the cache")
        XCTAssertEqual(url1, url2)
    }

    func testConcurrentEnsureBlobLocalDedupsToSingleFetch() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobDelayNanos = 50_000_000  // 50ms to force overlap
        let (coord, _, _) = makeCoordinator(store: store)

        async let r1 = coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        async let r2 = coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        async let r3 = coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        async let r4 = coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        let urls = try await [r1, r2, r3, r4]

        XCTAssertEqual(store.fetchBlobCount, 1, "Concurrent callers share one fetch")
        XCTAssertEqual(Set(urls).count, 1)
    }

    func testEvictRemovesLocalKeepsCloud() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        try await coord.evict(recordName: "m1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })

        XCTAssertEqual(store.fetchBlobCount, 2, "Eviction forces a re-fetch from cloud")
    }

    func testChangeTagInvalidationRefetches() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1", tag: "t1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1", tag: "t2")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 2, "A new change tag invalidates the stale cached file")
    }

    func testEvictAllOlderThanForcesRefetch() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        try await coord.evictAll(olderThan: Date().addingTimeInterval(60))   // future => evicts all
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })

        XCTAssertEqual(store.fetchBlobCount, 2)
    }

    // MARK: - Download cancel / retry

    /// A cancelled download must actually stop. Awaiting an unstructured
    /// `Task.value` ignores the awaiting task's cancellation, so tapping Cancel
    /// left the caller parked for the full remaining download AND left the
    /// CloudKit fetch running.
    func testCancellingTheOnlyWaiterStopsTheFetchAndThrowsCancellation() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let download = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in }) }
        await fulfillment(of: [inFlight], timeout: 5)
        download.cancel()

        do {
            _ = try await withTimeout(seconds: 3) { try await download.value }
            XCTFail("A cancelled download must not resolve — the caller has to be released immediately")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(store.fetchBlobCancelledCount, 1,
                       "The CloudKit fetch itself must be cancelled once its last waiter goes away")
    }

    /// A cancelled download must leave nothing behind. This is the timing-free
    /// statement of "the transfer really stopped" — and the property the on-device
    /// probe asserts, because a rig's link is far too fast to judge by the clock.
    func testCancelledDownloadLeavesNothingInTheBlobCache() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let download = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in }) }
        await fulfillment(of: [inFlight], timeout: 5)
        download.cancel()
        _ = try? await withTimeout(seconds: 3) { try await download.value }

        // Well past when the abandoned fetch would have finished.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let cached = await coord.isBlobCached(recordName: "m1")
        XCTAssertFalse(cached, "A cancelled download must not go on to finish and cache its blob")
    }

    /// The reported bug: start a download, cancel it, start it again — the second
    /// attempt froze at 0% (or at whatever the first attempt last showed) because
    /// it joined the abandoned fetch, whose progress closure belonged to the
    /// cancelled caller.
    func testDownloadRestartedAfterACancelReportsProgressAndCompletes() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the first download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let abandoned = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in }) }
        await fulfillment(of: [inFlight], timeout: 5)
        abandoned.cancel()

        let retry = ProgressRecorder()
        let url = try await withTimeout(seconds: 15) {
            try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: retry.record)
        }

        XCTAssertFalse(retry.values.isEmpty,
                       "The restarted download must report progress; a silent one is the frozen bar the user sees")
        XCTAssertEqual(retry.values.last, 1.0, "The restarted download must finish at 100%")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The retry must produce a readable blob")
    }

    /// Two callers for the same record still share one fetch — but the joiner has
    /// to be fed progress too, and to start from where the download actually is.
    func testJoiningCallerReceivesProgressFromTheSharedFetch() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let first = ProgressRecorder()
        let joiner = ProgressRecorder()
        let leader = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: first.record) }
        await fulfillment(of: [inFlight], timeout: 5)

        let joinedURL = try await withTimeout(seconds: 15) {
            try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: joiner.record)
        }
        let leaderURL = try await leader.value

        XCTAssertEqual(store.fetchBlobCount, 1, "Concurrent callers must still share one fetch")
        XCTAssertEqual(joinedURL, leaderURL)
        XCTAssertFalse(joiner.values.isEmpty, "A joiner must see the shared download's progress")
        XCTAssertEqual(joiner.values.last, 1.0)
        XCTAssertGreaterThanOrEqual(joiner.values.first ?? 0, 0.2,
                                    "A joiner must start from the fraction already reached, not from zero")
    }

    /// Cancelling one caller must not strand the others: the fetch is cancelled
    /// only when the LAST interested caller goes away.
    func testCancellingOneWaiterLeavesTheSharedDownloadRunningForTheOther() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let stayer = ProgressRecorder()
        let leaving = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in }) }
        await fulfillment(of: [inFlight], timeout: 5)
        let staying = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: stayer.record) }
        // Let the second caller register before the first one walks away.
        try await Task.sleep(nanoseconds: 100_000_000)
        leaving.cancel()

        let url = try await withTimeout(seconds: 15) { try await staying.value }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.fetchBlobCancelledCount, 0,
                       "A fetch with a remaining waiter must not be cancelled")
        XCTAssertEqual(store.fetchBlobCount, 1, "The remaining waiter keeps the original fetch, it does not restart it")
    }

    // MARK: - Cross-device delete

    func testRemoveDeletesTheRecordImmediately() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        try await coord.remove(recordName: "m1", albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"], "The record is removed now, not soft-deleted and swept later")
        let afterRemove = await ids(index)
        XCTAssertTrue(afterRemove.isEmpty)

        // A delete that lands mid-fetch wins.
        do {
            _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
            XCTFail("Expected notFound for a deleted record")
        } catch let error as CloudKitMediaStoreError {
            guard case .notFound = error else { return XCTFail("Wrong error: \(error)") }
        }

        // A confirmed delete leaves the queue, so no later pass re-issues it.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"], "A confirmed delete must not be retried")
    }

    /// A delete the server refuses is not lost: it is persisted and retried by the
    /// next sync, and until it lands the record must not be pulled back into the
    /// index from its still-live remote copy.
    func testAFailedDeleteIsRetriedAndDoesNotResurrectTheRecord() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // A server that keeps refusing: the intent must survive and keep retrying.
        store.deleteError = CloudKitMediaStoreError.retry(after: 1)
        try await coord.remove(recordName: "m1", albumID: "a1")

        let afterFailedDelete = await ids(index)
        XCTAssertTrue(afterFailedDelete.isEmpty,
                      "The item leaves this device even when the server call fails")

        // The record is still live server-side, so the feed keeps reporting it. It
        // must not be pulled back onto the device that deleted it.
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.deleteCalls, ["m1", "m1"], "The queued delete is retried on the next sync")
        let afterRetry = await ids(index)
        XCTAssertTrue(afterRetry.isEmpty, "A record pending deletion must never be re-materialized")

        // Once the server accepts it, the intent is discharged.
        store.deleteError = nil
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1", "m1", "m1"])

        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1", "m1", "m1"], "A drained delete is not retried again")
    }

    /// The retry survives the process: the intent lives in the queue, not in the
    /// coordinator that formed it.
    func testAQueuedDeleteIsRetriedByAFreshCoordinator() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let (coord, _, _) = makeCoordinator(store: store, deleteQueue: queue)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.deleteErrorOnce = CloudKitMediaStoreError.retry(after: 1)
        try await coord.remove(recordName: "m1", albumID: "a1")
        XCTAssertEqual(queue.pending(), ["m1"], "An unconfirmed delete is persisted")

        // A new coordinator over the same queue — what relaunch looks like.
        let (fresh, _, _) = makeCoordinator(store: store, deleteQueue: queue)
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await fresh.sync(albumID: "a1")

        XCTAssertEqual(store.deleteCalls, ["m1", "m1"])
        XCTAssertTrue(queue.pending().isEmpty, "A confirmed delete drains")
    }

    func testObservedLegacyTombstoneIsReclaimed() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // A record soft-deleted by an older build. Nothing writes these any more,
        // but they still sit in dev and TestFlight zones holding a full-size blob
        // against the user's quota, so observing one must reclaim it.
        store.changeSet = CloudKitChangeSet(changed: [meta("m1", deletedAt: Date())], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let result = await ids(index)
        XCTAssertTrue(result.isEmpty, "The item leaves the index as soon as the tombstone is seen")

        // The drain runs before the feed is read, so the record it queues is
        // reclaimed on the following pass.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"], "An observed legacy tombstone must end in a real delete")
    }

    func testCachedBlobSurvivesRelaunchBeforeTagMapRepopulates() async throws {
        let store = MockCloudKitMediaStore()
        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: FileOperationBus())

        store.changeSet = CloudKitChangeSet(changed: [meta("m1", tag: "t1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)

        // "Relaunch": a fresh coordinator over the SAME persisted cache, before any
        // delta sync has repopulated its in-memory change-tag map. The persisted
        // entry must be trusted (nil expectation), not re-downloaded wholesale.
        let relaunched = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: FileOperationBus())
        _ = try await relaunched.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1, "A persisted cache entry with no newer known tag must be a hit after relaunch")
    }

    // MARK: - Push / notifications

    func testStartObservingSkipsSubscriptionWhenNoAccount() async {
        let store = MockCloudKitMediaStore()
        store.accountAvailableValue = false
        let (coord, _, _) = makeCoordinator(store: store)

        await coord.startObserving()
        XCTAssertEqual(store.registerSubscriptionCount, 0)

        store.accountAvailableValue = true
        await coord.startObserving()
        XCTAssertEqual(store.registerSubscriptionCount, 1)
    }

    func testSyncRetriesFailedSubscriptionRegistration() async throws {
        let store = MockCloudKitMediaStore()
        store.registerSubscriptionError = CloudKitMediaStoreError.retry(after: 0)
        let (coord, _, _) = makeCoordinator(store: store)

        await coord.startObserving()
        XCTAssertEqual(store.registerSubscriptionCount, 0, "registration failed and was not recorded")

        store.registerSubscriptionError = nil
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.registerSubscriptionCount, 1,
                       "a sync self-heals a previously failed push registration")
    }

    func testEverySyncReattemptsRegistrationSoStoreInvalidationSelfHeals() async throws {
        // `CloudKitMediaStore.mapAndRecord` clears its persisted subscription flag
        // on `.zoneNotFound` (zone deleted in iCloud Settings, account wiped)
        // precisely so the next registration attempt re-creates the subscription.
        // The coordinator must therefore hand the store that chance on EVERY sync:
        // a cached in-memory "already registered" bool goes stale-true the moment
        // the store invalidates, silently killing push-driven sync for the life of
        // the process. Dedup belongs to the store, whose persisted-flag check makes
        // a genuinely-registered attempt a cheap no-op.
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        try await coord.sync(albumID: "a1")
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.registerSubscriptionCount, 2,
                       "each sync must delegate the register-or-no-op decision to the store")
    }

    func testRemoteNotificationTriggersSync() async {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        await coord.handleRemoteNotification([:])

        XCTAssertEqual(store.fetchChangesCount, 1)
        let result = await ids(index)
        XCTAssertEqual(result, ["m1"])
    }

    func testEmitsFileOperationBusEvents() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let created = CapturedIDs()
        let deleted = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            switch operation {
            case .create(let media): created.append(media.id)
            case .delete(let medias): deleted.append(contentsOf: medias.map { $0.id })
            case .move: break
            }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)

        // First add m1 and m2, then delete m2 — a delete only fires for an item this
        // album actually held (deletes are album-scoped against the shared zone).
        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["m2"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(created.values, ["m1", "m2"])
        XCTAssertEqual(deleted.values, ["m2"])
    }

    // MARK: - Bugbot regressions

    /// A stale hard-delete (record already gone elsewhere) must not abort the whole sync.
    func testSyncToleratesARecordAlreadyGoneFromTheZone() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // The server no longer has it — deleted from another device first.
        store.deleteError = CloudKitMediaStoreError.notFound
        try await coord.remove(recordName: "m1", albumID: "a1")

        // Must not throw, and must not keep retrying forever: nothing to delete is
        // success for a delete.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"], "A notFound delete should be dropped, not retried")
    }

    /// A Live Photo arrives as two records sharing one mediaID; the index entry must
    /// carry both components or `materialize` drops the item from the gallery.
    func testSyncMergesLivePhotoComponentsIntoOneEntry() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)

        try await coord.sync(albumID: "a1")

        let entries = await index.load()?.entries ?? []
        let entry = entries.first { $0.id == "live" }
        XCTAssertNotNil(entry, "The Live Photo must produce one index entry")
        XCTAssertEqual(entry?.hasPhotoComponent, true)
        XCTAssertEqual(entry?.hasVideoComponent, true)
    }

    /// Deleting ONE component of a Live Photo must keep the entry while the other
    /// component survives — only clear that component's flag.
    func testDeletingOneLivePhotoComponentKeepsTheOther() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // The photo component is removed from the zone; the video remains.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["live#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let entry = (await index.load()?.entries ?? []).first { $0.id == "live" }
        XCTAssertNotNil(entry, "The Live Photo must remain while one component survives")
        XCTAssertEqual(entry?.hasPhotoComponent, false)
        XCTAssertEqual(entry?.hasVideoComponent, true)
    }

    /// Removing the last surviving component drops the entry entirely.
    func testDeletingBothLivePhotoComponentsRemovesEntry() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["live#0", "live#1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let entry = (await index.load()?.entries ?? []).first { $0.id == "live" }
        XCTAssertNil(entry, "Both components gone => entry removed")
    }

    /// An expired change token must trigger a reset + full resync, not a hard failure.
    func testSyncRecoversFromExpiredChangeToken() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.fetchChangesErrorOnce = CloudKitMediaStoreError.changeTokenExpired
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)

        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.resetChangeTokenCount, 1, "Expired token should be reset")
        let entries = await ids(index)
        XCTAssertEqual(entries, ["m1"], "Resync after reset should populate the index")
    }

    /// Synced records must carry `dateEncrypted` so default gallery sorting (by
    /// encrypted date) orders them by capture time, not dumps them at the end.
    func testSyncedItemsCarryEncryptedDateForSorting() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        func dated(_ name: String, _ date: Date) -> CloudKitMediaMetadata {
            CloudKitMediaMetadata(recordName: name, albumID: "a1", mediaID: name, mediaType: .photo,
                                  createdAt: date, sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t-\(name)")
        }
        store.changeSet = CloudKitChangeSet(changed: [
            dated("old", Date(timeIntervalSince1970: 100)),
            dated("new", Date(timeIntervalSince1970: 200))
        ], deleted: [], token: nil, moreComing: false)

        try await coord.sync(albumID: "a1")

        let entries = await index.load()?.entries ?? []
        XCTAssertNotNil(entries.first { $0.id == "new" }?.dateEncrypted, "Synced entries need an encrypted date")
        let sorted = MediaIndex(entries: entries).sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
        XCTAssertEqual(sorted.map { $0.id }, ["new", "old"], "Newest capture first")
    }

    /// A record already present in the index must not re-emit a create on resync,
    /// or the gallery does redundant reconcile work for the whole album.
    func testSyncEmitsCreateOnlyForNewEntries() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let created = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            if case .create(let media) = operation { created.append(media.id) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")   // first time: create
        try await coord.sync(albumID: "a1")   // already present: no new create

        XCTAssertEqual(created.values, ["m1"], "Create should fire once, only for the genuinely new entry")
    }

    /// A delete for a record this album never held (another album in the shared zone)
    /// must not emit a delete event or mutate this coordinator's state.
    func testSyncIgnoresDeletesForOtherAlbums() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let deleted = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            if case .delete(let medias) = operation { deleted.append(contentsOf: medias.map { $0.id }) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // A delete for "other#0" — a record from a different album we never indexed.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["other#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertTrue(deleted.values.isEmpty, "Deletes for other albums must be ignored")
        let remaining = await ids(index)
        XCTAssertEqual(remaining, ["m1"], "Our album's index must be untouched")
    }

    // MARK: - Local artifact cleanup on delete

    /// The encrypted preview is a real file on disk, so a delete that removes the
    /// index entry and the cached blob but leaves the thumbnail behind is a silent
    /// leak that grows with every cross-device delete.
    func testCrossDeviceDeleteRemovesTheLocalPreview() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let previewURL = CloudKitStorageModel.previewURL(forMediaID: "m1")
        try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("thumbnail".utf8).write(to: previewURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: previewURL) }

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["m1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path),
                       "A hard delete must take the encrypted preview with it")
    }

    /// A Live Photo's two components share ONE preview file, so clearing the first
    /// component must not delete the thumbnail the surviving component still needs.
    func testDeletingOneLivePhotoComponentKeepsTheSharedPreview() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let previewURL = CloudKitStorageModel.previewURL(forMediaID: "live")
        try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("thumbnail".utf8).write(to: previewURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: previewURL) }

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["live#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path),
                      "The video component still needs the shared preview")
    }

    /// The cached ciphertext must be dropped even when the index entry is already
    /// gone — otherwise the blob is stranded on disk with nothing left to evict it.
    func testDeleteEvictsCachedBlobEvenWhenNotInThisAlbumsIndex() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, cache) = makeCoordinator(store: store)

        let source = tempRoot.appendingPathComponent("stranded.blob")
        try Data("ciphertext".utf8).write(to: source)
        _ = try await cache.store(recordName: "gone#0", changeTag: "t1", albumID: "a1", from: source)
        let cachedBefore = await cache.cachedURL(recordName: "gone#0", changeTag: "t1")
        XCTAssertNotNil(cachedBefore)

        // "gone#0" is not in this album's index at all.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["gone#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let cached = await cache.cachedURL(recordName: "gone#0", changeTag: "t1")
        XCTAssertNil(cached, "A record deleted from the zone must not keep a cached blob")
    }

    /// The record name encodes the component type, so a hard delete can emit a
    /// well-typed bus event instead of `.unknown`.
    func testHardDeleteEmitsTypedBusEvent() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let types = TypeRecorder()
        let cancellable = bus.operations.sink { operation in
            if case .delete(let medias) = operation { types.append(contentsOf: medias.map { $0.mediaType }) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: makeCache(), indexStore: index, bus: bus)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "v1#1", mediaID: "v1", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["v1#1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(types.values, [.video], "The component type is recoverable from the record name")
    }

    // MARK: - Reap on a full resync

    /// A record deleted while this device's token was expired never appears in the
    /// change feed, so only an acknowledged from-scratch fetch can notice it is gone.
    func testFullResyncReapsEntriesAbsentFromACompleteSnapshot() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")],
                                            deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        let afterFirst = await ids(index)
        XCTAssertEqual(afterFirst, ["m1", "m2"])

        // A complete snapshot that no longer contains m1: it was deleted elsewhere
        // and this device never saw the delete.
        store.changeSet = CloudKitChangeSet(changed: [meta("m2")], deleted: [],
                                            token: nil, moreComing: false, snapshotComplete: true)
        try await coord.sync(albumID: "a1")

        let afterSnapshot = await ids(index)
        XCTAssertEqual(afterSnapshot, ["m2"], "A record absent from a complete snapshot is gone")
    }

    /// Absence only means deletion when the server acknowledged the fetch. An
    /// unacknowledged answer may be partial, and reaping on it deletes live media.
    func testUnacknowledgedFullFetchDoesNotReap() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")],
                                            deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [meta("m2")], deleted: [],
                                            token: nil, moreComing: false, snapshotComplete: false)
        try await coord.sync(albumID: "a1")

        let afterUnacked = await ids(index)
        XCTAssertEqual(afterUnacked, ["m1", "m2"], "Never reap on an answer we cannot vouch for")
    }

    /// A capture that has not uploaded yet is legitimately in the index and
    /// legitimately absent from the server. Reaping it would delete the user's
    /// photo before its bytes ever left the device.
    func testReapExemptsItemsStillWaitingToUpload() async throws {
        let store = MockCloudKitMediaStore()
        let queue = CloudKitUploadQueue(baseDir: tempRoot.appendingPathComponent("q-\(UUID().uuidString)"))
        let index = makeIndexStore()
        let coord = CloudKitSyncCoordinator(albumID: "a1",
                                            store: store,
                                            cache: makeCache(),
                                            indexStore: index,
                                            bus: FileOperationBus(),
                                            uploadQueue: queue)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // A second item exists locally and is still queued for upload.
        let pendingFile = tempRoot.appendingPathComponent("pending.blob")
        try Data("ciphertext".utf8).write(to: pendingFile)
        _ = try await queue.enqueue(CloudKitMediaUpload(albumID: "a1",
                                                        mediaID: "queued",
                                                        mediaType: .photo,
                                                        createdAt: Date(),
                                                        sizeBytes: 10,
                                                        encryptedFileURL: pendingFile,
                                                        encryptedThumbURL: nil,
                                                        recordName: "queued#0"))
        try await index.upsert([MediaIndexEntry(id: "queued",
                                                hasPhotoComponent: true,
                                                hasVideoComponent: false,
                                                dateEncrypted: Date(),
                                                dateTaken: Date(),
                                                subtypeRawValue: 0)])

        // A complete snapshot containing only the uploaded item.
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [],
                                            token: nil, moreComing: false, snapshotComplete: true)
        try await coord.sync(albumID: "a1")

        let afterReap = await ids(index)
        XCTAssertEqual(afterReap, ["m1", "queued"],
                       "An item still waiting to upload must survive the reap")
    }

    /// A merge that adds a component (Live Photo video arriving after the photo)
    /// changes the entry, so the gallery must be told to refresh.
    func testLivePhotoMergeEmitsRefresh() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let created = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            if case .create(let media) = operation { created.append(media.id) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)

        store.changeSet = CloudKitChangeSet(changed: [metaComponent(recordName: "live#0", mediaID: "live", type: .photo)], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")   // photo arrives -> create
        store.changeSet = CloudKitChangeSet(changed: [metaComponent(recordName: "live#1", mediaID: "live", type: .video)], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")   // video merges in -> refresh

        XCTAssertEqual(created.values, ["live", "live"], "Adding a component must refresh the gallery")
    }

    /// A locally uploaded item must sort consistently with synced items: use the
    /// capture date for `dateEncrypted`, not the wall clock at upload time.
    /// Moving an album out of iCloud calls `remove` for every item, which marks each
    /// record deleted-locally and queues it for a hard purge. Both live in memory on
    /// the album's coordinator, and the registry hands the SAME coordinator back when
    /// the album is moved to iCloud again — so the re-upload lands on bookkeeping
    /// that still says "this record is deleted".
    ///
    /// Left alone, the "a delete that raced this upload wins" guard fires on the very
    /// record the user just asked to upload: it tombstones the fresh record, throws
    /// `.cancelled`, and the queued purge then hard-deletes the photo from iCloud.
    /// The user's album reports a successful move and the media is gone.
    func testUploadAfterTheAlbumMovedOutOfICloudIsANewRecordNotADeleteRace() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // The iCloud -> local move: delete the record and drop it locally.
        try await coord.remove(recordName: "m1", albumID: "a1")

        // The local -> iCloud move back: the same record name is uploaded again.
        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/m1.blob"),
                                         encryptedThumbURL: nil)
        _ = try await coord.upload(upload, progress: { _ in })

        XCTAssertEqual(store.deleteCalls, ["m1"],
                       "The only delete belongs to the move out of iCloud — the re-upload must not be deleted")
        let entries = await ids(index)
        XCTAssertEqual(entries, ["m1"], "The re-uploaded record must be back in the local index")

        // And nothing queued by the move-out may reap what was just uploaded.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"],
                       "A stale delete must be cancelled by the re-upload, not delete the user's photo from iCloud")
    }

    /// The re-upload does not always run on the coordinator that queued the delete.
    /// Moving an album back into iCloud drives a `CloudKitSyncCoordinator` the
    /// migration manager builds for itself, while the delete was queued by the
    /// registry's long-lived coordinator for the same album. That one wakes up on
    /// its next sync — and used to hard-delete the records the migration had just
    /// re-published. Verified on the rig, where a migration reporting COMPLETED was
    /// followed by three `purge ok` lines and an album showing zero items.
    ///
    /// Making the queue durable and process-wide is what fixes it: republishing a
    /// record name clears the pending delete for that name whichever coordinator
    /// does the publishing, so no "is it still there?" round trip is needed.
    func testARepublishedRecordCancelsAPendingDeleteQueuedByAnotherCoordinator() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let (registryCoord, _, _) = makeCoordinator(store: store, deleteQueue: queue)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await registryCoord.sync(albumID: "a1")

        // The move out fails its delete, so the intent stays queued.
        store.deleteErrorOnce = CloudKitMediaStoreError.retry(after: 1)
        try await registryCoord.remove(recordName: "m1", albumID: "a1")
        XCTAssertEqual(queue.pending(), ["m1"])

        // The move back runs on a DIFFERENT coordinator over the same queue.
        let (migrationCoord, _, _) = makeCoordinator(store: store, deleteQueue: queue)
        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/m1.blob"),
                                         encryptedThumbURL: nil)
        _ = try await migrationCoord.upload(upload, progress: { _ in })

        XCTAssertTrue(queue.pending().isEmpty,
                      "Republishing the name must cancel the delete the other coordinator queued")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await registryCoord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"],
                       "Only the failed move-out delete — the fresh copy must never be deleted")

        // And the stale local "known deleted" mark must go with it, or reading the
        // revived photo still fails closed.
        _ = try await migrationCoord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
    }

    /// The guard the fix above must NOT weaken: a delete issued while the bytes are
    /// genuinely in flight still wins, and the record that lands is reclaimed.
    func testADeleteThatLandsDuringAnUploadStillWins() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // Delete lands *after* the upload has begun: the store call is where the
        // bytes are in flight, so that is where the racing remove is injected.
        store.onUploadStarted = { [weak coord] in
            guard let coord else { return }
            try? await coord.remove(recordName: "m1", albumID: "a1")
        }
        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/m1.blob"),
                                         encryptedThumbURL: nil)

        do {
            _ = try await coord.upload(upload, progress: { _ in })
            XCTFail("An upload that lost the race to a delete must not report success")
        } catch let error as CloudKitMediaStoreError {
            guard case .cancelled = error else { return XCTFail("Wrong error: \(error)") }
        }

        let entries = await ids(index)
        XCTAssertTrue(entries.isEmpty, "A photo deleted mid-upload must not be resurrected in the index")
        XCTAssertEqual(store.deleteCalls.filter { $0 == "m1" }.count, 2,
                       "Both the delete itself and the record that landed after it must be removed")
    }

    func testUploadEntryUsesCreatedAtForSorting() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)
        let captured = Date(timeIntervalSince1970: 555)
        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "u1", mediaType: .photo,
                                         createdAt: captured, sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/x.blob"),
                                         encryptedThumbURL: URL(fileURLWithPath: "/tmp/x.thumb"))

        _ = try await coord.upload(upload, progress: { _ in })

        let entry = (await index.load()?.entries ?? []).first { $0.id == "u1" }
        XCTAssertEqual(entry?.dateEncrypted, captured)
    }

    /// A wiped/missing index while a change token is still set must force a full
    /// resync — otherwise the token skips historical records and the album stays empty.
    func testSyncRebuildsIndexWhenWipedButTokenExists() async throws {
        let store = MockCloudKitMediaStore()
        store.hasChangeTokenValue = true
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)   // fresh index file => load() == nil

        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.resetChangeTokenCount, 1, "Wiped index with a token must force a full resync")
        let rebuilt = await ids(index)
        XCTAssertEqual(rebuilt, ["m1"])
    }

    /// An intact index must NOT force a resync just because a token exists.
    func testSyncDoesNotResetTokenWhenIndexPresent() async throws {
        let store = MockCloudKitMediaStore()
        store.hasChangeTokenValue = true
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")        // index missing first time => one reset
        let resetsAfterFirst = store.resetChangeTokenCount

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")        // index now present => no extra reset

        XCTAssertEqual(store.resetChangeTokenCount, resetsAfterFirst, "An intact index must not force a resync")
    }

    /// Concurrent syncs on one coordinator must coalesce, not each run a full
    /// load–merge–save that races the index and re-advances the token.
    func testConcurrentSyncsAreCoalesced() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchChangesDelayNanos = 50_000_000  // 50ms so the calls overlap
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, _, _) = makeCoordinator(store: store)

        async let s1: Void = coord.sync(albumID: "a1")
        async let s2: Void = coord.sync(albumID: "a1")
        async let s3: Void = coord.sync(albumID: "a1")
        async let s4: Void = coord.sync(albumID: "a1")
        _ = try await [s1, s2, s3, s4]

        XCTAssertLessThanOrEqual(store.fetchChangesCount, 2, "Overlapping syncs must coalesce, not run once each")
    }

    /// A coalesced sync must still WAIT for the in-flight run to finish (and pick up
    /// the caller's request), not return early before changes are applied.
    func testCoalescedSyncWaitsForCompletion() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchChangesDelayNanos = 80_000_000   // 80ms
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        let first = Task { try await coord.sync(albumID: "a1") }
        try await Task.sleep(nanoseconds: 15_000_000)   // let `first` enter the slow fetch
        try await coord.sync(albumID: "a1")             // coalesced — must wait, not return early

        let entries = await ids(index)
        XCTAssertEqual(entries, ["m1"], "A coalesced sync must not return before the index is applied")
        try await first.value
    }

    /// The registry hands back one coordinator per album id so the active album and
    /// the push fan-out share in-memory state.
    func testCoordinatorRegistryReturnsSameInstance() async {
        let registry = CloudKitCoordinatorRegistry()
        let make: () -> CloudKitSyncCoordinator = {
            CloudKitSyncCoordinator(albumID: "a1", store: MockCloudKitMediaStore(),
                                    cache: CloudKitBlobCache.shared, indexStore: self.makeIndexStore())
        }
        let c1 = await registry.coordinator(forAlbumID: "a1", make: make)
        let c2 = await registry.coordinator(forAlbumID: "a1", make: make)
        XCTAssertTrue(c1 === c2, "Same album id must reuse one coordinator")
    }

    /// After an `upload`, reading the index must serve from the store's warm cache
    /// rather than re-decrypting the file on every access — the asymmetry that the
    /// cloud path used to have (no cache at all) is gone now that the coordinator
    /// mutates through the stateful store.
    func testUploadThenReadServesFromCacheWithoutReload() async throws {
        let url = tempRoot.appendingPathComponent("\(UUID().uuidString).encindex")
        let index = MediaIndexStore(keyBytes: Array(repeating: 7, count: 32), indexURL: url)
        let store = MockCloudKitMediaStore()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: makeCache(),
                                            indexStore: index, bus: FileOperationBus())

        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "u1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/x.blob"),
                                         encryptedThumbURL: URL(fileURLWithPath: "/tmp/x.thumb"))
        _ = try await coord.upload(upload, progress: { _ in })

        // The upload warmed the store cache. Delete the on-disk file underneath: a
        // path that re-read disk every time would now surface an empty index, but
        // the read-through cache must still serve the uploaded entry.
        let warm = await index.current()
        XCTAssertEqual(warm?.entries.map(\.id), ["u1"])
        try FileManager.default.removeItem(at: url)
        let afterDelete = await index.current()
        XCTAssertEqual(afterDelete?.entries.map(\.id), ["u1"],
                       "the cloud read path must serve from the warm cache, not re-decrypt the file each time")
    }

    // Reference holder for Combine sink captures.
    private final class CapturedIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ id: String) { lock.lock(); storage.append(id); lock.unlock() }
        func append(contentsOf ids: [String]) { lock.lock(); storage.append(contentsOf: ids); lock.unlock() }
    }

    private final class TypeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MediaType] = []
        var values: [MediaType] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(contentsOf types: [MediaType]) { lock.lock(); storage.append(contentsOf: types); lock.unlock() }
    }
}
