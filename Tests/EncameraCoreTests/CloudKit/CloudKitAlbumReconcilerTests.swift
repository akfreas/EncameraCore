//
//  CloudKitAlbumReconcilerTests.swift
//  EncameraCoreTests
//
//  Chunk 13: cross-device album materialization. Exercises the album-id ↔ key
//  matching, the two-way reconcile (pull/push), key-availability gating, and the
//  in-memory store's album CRUD. Filesystem materialization + the full two-device
//  round-trip are covered by the e2e verification in the plan.
//

import XCTest
@testable import EncameraCore

final class CloudKitAlbumReconcilerTests: XCTestCase {

    // MARK: - Helpers

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeKey(_ seed: UInt8) -> PrivateKey {
        PrivateKey(name: "key-\(seed)", keyBytes: Array(repeating: seed, count: 32), creationDate: Date())
    }

    /// Build the remote album record exactly as a device would: encName is the
    /// album-name ciphertext under the album's key; albumID is its keyed hash.
    private func remoteRecord(name: String, key: PrivateKey, isHidden: Bool = false, deleted: Bool = false) -> CloudKitAlbumMetadata {
        let album = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key)
        let hash = SyncedStoreEncryptionHandler.keyedHash(name, keyBytes: key.keyBytes)!
        return CloudKitAlbumMetadata(albumID: hash,
                                     encName: album.encryptedPathComponent,
                                     createdAt: Date(),
                                     isHidden: isHidden,
                                     deletedAt: deleted ? Date() : nil,
                                     schemaVersion: CloudKitSchema.currentSchemaVersion,
                                     keyFingerprint: key.keychainLabel,
                                     recordChangeTag: "tag")
    }

    private func freshTombstoneQueue(_ name: String = #function) -> CloudKitAlbumTombstoneQueue {
        CloudKitAlbumTombstoneQueue(defaults: makeIsolatedDefaults(name))
    }

    private func makeReconciler(store: CloudKitMediaStoring,
                                keys: [PrivateKey],
                                albums: [Album],
                                tombstoneQueue: CloudKitAlbumTombstoneQueue? = nil,
                                function: String = #function) -> (CloudKitAlbumReconciler, MockAlbumManager) {
        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = keys
        keyManager.currentKey = keys.first
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = albums
        let reconciler = CloudKitAlbumReconciler(store: store,
                                                 keyManager: keyManager,
                                                 albumManager: albumManager,
                                                 tombstoneQueue: tombstoneQueue ?? freshTombstoneQueue(function))
        return (reconciler, albumManager)
    }

    // MARK: - match (pure)

    func test_match_findsOwningKeyAndRecoversName() {
        let owner = makeKey(7)
        let other = makeKey(3)
        let record = remoteRecord(name: "Vacation", key: owner)

        let result = CloudKitAlbumReconciler.match(record: record, keys: [other, owner])

        XCTAssertEqual(result?.name, "Vacation")
        XCTAssertEqual(result?.key.keyBytes, owner.keyBytes)
    }

    func test_match_returnsNilWhenNoKeyOwnsTheRecord() {
        let owner = makeKey(7)
        let record = remoteRecord(name: "Secret", key: owner)

        XCTAssertNil(CloudKitAlbumReconciler.match(record: record, keys: [makeKey(1), makeKey(2)]))
    }

    // MARK: - reconcile (push / gating / account)

    func test_reconcile_pushesLocalOnlyAlbumUp() async {
        let key = makeKey(5)
        let local = Album(name: "OnlyHere", storageOption: .cloudKit, creationDate: Date(), key: key)
        let store = MockCloudKitMediaStore()
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [local])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 0)
        let expectedHash = SyncedStoreEncryptionHandler.keyedHash("OnlyHere", keyBytes: key.keyBytes)!
        XCTAssertEqual(store.savedAlbumCalls.map { $0.albumID }, [expectedHash])
        XCTAssertEqual(store.savedAlbumCalls.first?.keyFingerprint, key.keychainLabel,
                       "the self-heal push must stamp the album with the key that encrypts it")
    }

    func test_reconcile_reportsLockedOutWhenKeyMissing() async {
        // A remote album owned by a key this device does NOT have (key backup off).
        let absentOwner = makeKey(9)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Remote", key: absentOwner))
        let (reconciler, _) = makeReconciler(store: store, keys: [makeKey(1)], albums: [])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 1)
        XCTAssertTrue(store.savedAlbumCalls.isEmpty)   // nothing materialized or pushed
    }

    /// ENC-99: the locked-out count has been computed since this reconciler was
    /// written and consumed by nothing, so locked albums were simply absent from
    /// the grid with nothing said. This pins that the count now travels all the
    /// way to the layer the UI observes.
    @MainActor
    func testLockedOutAlbumCountIsSurfaced() async {
        LockedAlbumsReporter.shared.report(lockedAlbumCount: 0)

        // Same condition as test_reconcile_reportsLockedOutWhenKeyMissing: two
        // remote albums owned by keys this device does not hold.
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "RemoteOne", key: makeKey(9)))
        store.seedAlbum(remoteRecord(name: "RemoteTwo", key: makeKey(8)))

        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = [makeKey(1)]
        keyManager.currentKey = keyManager.storedKeysValue.first
        let albumManager = MockAlbumManager(keyManager: keyManager)
        // A local .cloudKit album keeps performSyncAll from short-circuiting on
        // the inactive-CloudKit-plane guard, independent of the feature flag.
        albumManager.albumsOnDisk = [Album(name: "Local", storageOption: .cloudKit, creationDate: Date(), key: keyManager.currentKey!)]

        let queue = freshTombstoneQueue()
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false, makeReconciler: { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    tombstoneQueue: queue)
        })

        await sync.syncAll()

        let reported = await sync.albumsNeedingKey
        XCTAssertEqual(reported, 2, "both unreadable remote albums are counted")
        XCTAssertEqual(LockedAlbumsReporter.shared.lockedAlbumCount, 2,
                       "the count must reach the observable the album grid reads")
    }

    /// The banner must clear itself once the keys are present, or it would
    /// permanently accuse the app of hiding albums that are now visible.
    @MainActor
    func testLockedOutCountClearsWhenKeysArePresent() async {
        LockedAlbumsReporter.shared.report(lockedAlbumCount: 3)

        let owner = makeKey(9)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "RemoteOne", key: owner))

        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = [owner]
        keyManager.currentKey = owner
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [Album(name: "Local", storageOption: .cloudKit, creationDate: Date(), key: owner)]

        let queue = freshTombstoneQueue()
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false, makeReconciler: { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    tombstoneQueue: queue)
        })

        await sync.syncAll()

        XCTAssertEqual(LockedAlbumsReporter.shared.lockedAlbumCount, 0)
    }

    /// The CloudKit plane going inactive has to clear the banner too. `report`
    /// is the only writer of the observable, and it sits below the skip guard,
    /// so a count from a flag-on period used to stand for the rest of the
    /// process — naming albums the reconciler had stopped looking for.
    @MainActor
    func testLockedOutCountClearsWhenTheCloudKitPlaneGoesInactive() async {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }

        LockedAlbumsReporter.shared.report(lockedAlbumCount: 2)

        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = [makeKey(1)]
        keyManager.currentKey = keyManager.storedKeysValue.first
        let albumManager = MockAlbumManager(keyManager: keyManager)
        // No local `.cloudKit` album, so with the flag off the guard skips the
        // whole run — exactly the path that left the count standing.
        albumManager.albumsOnDisk = []

        let store = MockCloudKitMediaStore()
        let queue = freshTombstoneQueue()
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false, makeReconciler: { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    tombstoneQueue: queue)
        })

        await sync.syncAll()

        let reported = await sync.albumsNeedingKey
        XCTAssertEqual(reported, 0)
        XCTAssertEqual(LockedAlbumsReporter.shared.lockedAlbumCount, 0,
                       "a skipped run must not leave the grid claiming albums are locked out")
    }

    func test_reconcile_noOpWhenAccountUnavailable() async {
        let key = makeKey(5)
        let local = Album(name: "Offline", storageOption: .cloudKit, creationDate: Date(), key: key)
        let store = MockCloudKitMediaStore()
        store.accountAvailableValue = false
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [local])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 0)
        XCTAssertTrue(store.savedAlbumCalls.isEmpty)
    }

    func test_reconcile_doesNotRePushAlbumAlreadyRemote() async {
        let key = makeKey(5)
        let local = Album(name: "Synced", storageOption: .cloudKit, creationDate: Date(), key: key)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Synced", key: key))   // already on the server
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [local])

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "an album already present remotely must not be re-pushed")
    }

    // MARK: - Pull routing through the manager

    func test_reconcile_materializesRemoteAlbumThroughTheManager() async {
        let key = makeKey(5)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "FromOtherDevice", key: key, isHidden: true))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 0)
        XCTAssertEqual(albumManager.adoptedAlbums.map { $0.name }, ["FromOtherDevice"],
                       "materialization must go through AlbumManaging so observers are notified")
        XCTAssertEqual(albumManager.adoptedAlbums.first?.isHidden, true)
    }

    func test_reconcile_removesTombstonedAlbumViaManagerDelete() async {
        let key = makeKey(5)
        let local = Album(name: "Gone", storageOption: .cloudKit, creationDate: Date(), key: key)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Gone", key: key, deleted: true))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local])

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(albumManager.deletedAlbums.map { $0.name }, ["Gone"],
                       "a tombstoned remote album must be removed via AlbumManaging.delete so broadcasts, currentAlbum, and hidden-state cleanup all run")
    }

    func test_reconcile_doesNotOverwriteLocalHiddenStateOfExistingAlbum() async {
        // The user hid the album locally; the record still says isHidden == false
        // (it's only written at create-time / explicit toggles). Reconcile must NOT
        // un-hide it on every scene-active.
        let key = makeKey(5)
        let local = Album(name: "Private", storageOption: .cloudKit, creationDate: Date(), key: key)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Private", key: key, isHidden: false))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local])
        albumManager.hiddenAlbumNames = ["Private"]

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(albumManager.setHiddenCalls.isEmpty,
                      "an existing album's hidden state must not be driven by the EncAlbum record")
        XCTAssertTrue(albumManager.isAlbumHidden(local))
    }

    // MARK: - Durable pending tombstones

    func test_reconcile_drainsPendingTombstoneAndDoesNotResurrectAlbum() async {
        // Device deleted "Doomed" offline: the local marker is gone, the durable
        // tombstone intent is queued, and the remote record is still live.
        let key = makeKey(5)
        let hash = SyncedStoreEncryptionHandler.keyedHash("Doomed", keyBytes: key.keyBytes)!
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Doomed", key: key))
        let queue = freshTombstoneQueue()
        queue.enqueue(hash)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [], tombstoneQueue: queue)

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(store.tombstonedAlbumCalls, [hash], "the pending tombstone must be drained to the server")
        XCTAssertTrue(queue.pending().isEmpty, "a confirmed tombstone leaves the queue")
        XCTAssertTrue(albumManager.adoptedAlbums.isEmpty,
                      "a locally-deleted album must not be resurrected from its still-live remote record")
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "nothing to self-heal push")
    }

    // MARK: - In-memory store album CRUD

    func test_inMemoryStore_saveAlbumIsIdempotentAndTombstones() async throws {
        let store = InMemoryCloudKitMediaStore()
        let upload = CloudKitAlbumUpload(albumID: "hash-1", encName: "Album_xyz", createdAt: Date(), isHidden: false)

        try await store.saveAlbum(upload)
        try await store.saveAlbum(upload)   // idempotent: same record name
        var all = try await store.fetchAllAlbums()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all.first?.deletedAt)

        try await store.tombstoneAlbum(albumID: "hash-1")
        all = try await store.fetchAllAlbums()
        XCTAssertEqual(all.count, 1)
        XCTAssertNotNil(all.first?.deletedAt, "tombstone must set deletedAt for cross-device delete")
    }

    // MARK: - Tombstone queue

    /// The queue's writers race in production (`AlbumManager.delete` enqueues from the
    /// caller's thread while the reconciler drains on the `CloudKitAlbumsSync` actor);
    /// an unsynchronized read-modify-write drops entries computed from stale reads —
    /// and a lost tombstone intent is exactly the resurrection this queue prevents.
    func test_tombstoneQueue_concurrentMutationsLoseNoEntries() {
        let queue = freshTombstoneQueue()
        for i in 0..<100 { queue.enqueue("stale-\(i)") }
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i.isMultiple(of: 2) {
                queue.enqueue("fresh-\(i / 2)")
            } else {
                queue.remove("stale-\((i - 1) / 2)")
            }
        }
        let pending = queue.pending()
        XCTAssertEqual(pending.count, 100, "Racing enqueue/remove must not lose entries")
        XCTAssertTrue(pending.allSatisfy { $0.hasPrefix("fresh-") },
                      "All enqueued entries must survive and all removed entries must be gone")
    }
}
