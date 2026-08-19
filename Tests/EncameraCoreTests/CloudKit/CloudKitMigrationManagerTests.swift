//
//  CloudKitMigrationManagerTests.swift
//  EncameraCoreTests
//
//  Planning coverage for the local -> CloudKit migration engine: every component
//  becomes a stable, deterministically-named work item; re-planning is idempotent
//  and preserves progress; `.cloudKit` albums are rejected (local-only safety).
//

import XCTest
import UIKit
import CloudKit
import Combine
@testable import EncameraCore

@MainActor
final class CloudKitMigrationManagerTests: XCTestCase {

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeAlbum(storage: StorageType = .local) -> Album {
        let key = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        return Album(name: "mig-\(UUID().uuidString)", storageOption: storage, creationDate: Date(), key: key)
    }

    private func makeManager(for album: Album) -> (CloudKitMigrationManager, MockAlbumManager) {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        return (CloudKitMigrationManager(albumManager: albumManager), albumManager)
    }

    private func tinyPNG() -> Data {
        let size = CGSize(width: 2, height: 2)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    private func makePhoto(id: String = UUID().uuidString) throws -> InteractableMedia<CleartextMedia> {
        try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: id)
        ])
    }

    /// Lays down `count` real encrypted photos in a fresh local album and returns it.
    private func seedLocalAlbum(count: Int, albumManager: MockAlbumManager, album: Album) async throws -> [String] {
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        var ids: [String] = []
        for _ in 0..<count {
            let id = UUID().uuidString
            _ = try await backend.save(media: try makePhoto(id: id), metadata: nil, progress: { _ in })
            ids.append(id)
        }
        return ids
    }

    private func makeExecutableManager(for album: Album) -> (CloudKitMigrationManager, MockAlbumManager, MockCloudKitMediaStore) {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let store = MockCloudKitMediaStore()
        let manager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store })
        return (manager, albumManager, store)
    }

    private func sourceEncURL(album: Album, id: String) -> URL {
        album.storageOption.modelForType.init(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    private func cleanup(_ album: Album) {
        let model = album.storageOption.modelForType.init(album: album)
        try? FileManager.default.removeItem(at: model.baseURL)
        try? FileManager.default.removeItem(at: MigrationPlanStore.planURL(for: album))
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(Album.cloudKitTwin(of: album).encryptedPathComponent)
        try? FileManager.default.removeItem(at: marker)
        try? MediaIndexStore.clearAllIndexes()
    }

    // MARK: - merge (pure)

    func testMergePreservesProgressResetsFailedKeepsDeletedAndAbsentInProgress() {
        let a = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: .verified)
        let b = MigrationItem(mediaID: "b", recordName: "b#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: .failed, lastError: "boom")
        let c = MigrationItem(mediaID: "c", recordName: "c#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: .sourceDeleted)
        let d = MigrationItem(mediaID: "d", recordName: "d#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: .uploading)

        let freshA = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: Date(), sizeBytes: 99)
        let freshB = MigrationItem(mediaID: "b", recordName: "b#0", mediaType: .photo, createdAt: Date(), sizeBytes: 99)
        let freshE = MigrationItem(mediaID: "e", recordName: "e#0", mediaType: .photo, createdAt: Date(), sizeBytes: 99)

        let merged = CloudKitMigrationManager.merge(existing: [a, b, c, d], enumerated: [freshA, freshB, freshE])
        let byRecord = Dictionary(uniqueKeysWithValues: merged.map { ($0.recordName, $0) })

        XCTAssertEqual(byRecord["a#0"]?.state, .verified, "in-progress/verified items keep their state")
        XCTAssertEqual(byRecord["a#0"]?.sizeBytes, 10, "preserved items keep their prior fields")
        XCTAssertEqual(byRecord["b#0"]?.state, .pending, "a failed item is reset to pending so it retries")
        XCTAssertEqual(byRecord["b#0"]?.sizeBytes, 99, "and refreshed with the current size")
        XCTAssertEqual(byRecord["e#0"]?.state, .pending, "a newly-seen file becomes a pending item")
        XCTAssertEqual(byRecord["c#0"]?.state, .sourceDeleted, "a completed item absent from disk is preserved")
        XCTAssertEqual(byRecord["d#0"]?.state, .uploading,
                       "an in-progress item absent from disk is preserved, not dropped, so its CloudKit progress isn't lost")
        XCTAssertEqual(merged.count, 5)
    }

    // MARK: - Local-only safety

    func testPlanRejectsCloudKitAlbum() async throws {
        let album = makeAlbum(storage: .cloudKit)
        let (manager, _) = makeManager(for: album)
        do {
            _ = try await manager.plan(album: album)
            XCTFail("a .cloudKit album must not be planned for migration")
        } catch MigrationError.invalidSourceStorage(let storage) {
            XCTAssertEqual(storage, .cloudKit)
        }
    }

    // MARK: - Planning

    // `.icloud` sources are accepted — the engine materializes each batch of evicted
    // files before uploading it. That path lives in `ICloudDriveMigrationTests`,
    // which needs a substituted ubiquity container; only `.cloudKit` is refused
    // outright, and `testPlanRejectsCloudKitAlbum` above covers it.

    func testPlanCreatesPendingItemPerComponent() async throws {
        let album = makeAlbum()
        let (manager, albumManager) = makeManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 3, albumManager: albumManager, album: album)
        let plan = try await manager.plan(album: album)

        XCTAssertEqual(plan.items.count, 3)
        XCTAssertEqual(Set(plan.items.map(\.mediaID)), Set(ids))
        XCTAssertTrue(plan.items.allSatisfy { $0.state == .pending })
        XCTAssertTrue(plan.items.allSatisfy { $0.sizeBytes > 0 }, "size is read from the on-disk ciphertext")
        XCTAssertTrue(plan.items.allSatisfy { $0.recordName == "\($0.mediaID)#\(MediaType.photo.rawValue)" })
        XCTAssertEqual(plan.sourceStorage, .local)
        XCTAssertEqual(manager.progress.totalCount, 3)
    }

    func testStableMediaIDsAndRecordNamesAcrossReplan() async throws {
        let album = makeAlbum()
        let (manager, albumManager) = makeManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let first = try await manager.plan(album: album)
        let second = try await manager.plan(album: album)

        XCTAssertEqual(first.items.map(\.recordName).sorted(), second.items.map(\.recordName).sorted())
        XCTAssertEqual(first.items.map(\.mediaID).sorted(), second.items.map(\.mediaID).sorted())
    }

    func testReplanPreservesProgressedItems() async throws {
        let album = makeAlbum()
        let (manager, albumManager) = makeManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        // Simulate one item having already reached CloudKit (verified) before a relaunch.
        let store = MigrationPlanStore(album: album)
        let loaded = await store.load()
        var persisted = try XCTUnwrap(loaded)
        let verifiedRecord = persisted.items[0].recordName
        persisted.items[0].state = .verified
        try await store.save(persisted)

        let replanned = try await manager.plan(album: album)
        let item = try XCTUnwrap(replanned.items.first { $0.recordName == verifiedRecord })
        XCTAssertEqual(item.state, .verified, "re-planning must not undo work already done")
    }

    func testPlanPersistsEncryptedToDisk() async throws {
        let album = makeAlbum()
        let (manager, albumManager) = makeManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        XCTAssertTrue(MigrationPlanStore.hasPlan(for: album))
        let reloaded = await MigrationPlanStore(album: album).load()
        XCTAssertEqual(reloaded?.items.count, 1)
    }

    // MARK: - Execution

    func testHappyPathUploadsVerifiesAndDeletesSource() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 3, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(manager.progress.fractionComplete, 1.0, accuracy: 0.0001)
        XCTAssertEqual(store.uploadCalls.count, 3, "each component uploads exactly once")
        XCTAssertEqual(albumManager.finalizeCallCount, 1, "the album flips to CloudKit exactly once")
        XCTAssertFalse(MigrationPlanStore.hasPlan(for: album), "the checkpoint is removed on completion")

        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                           "the local original is deleted after a verified upload")
        }
    }

    func testSourceNotDeletedWhenVerifyFails() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = false   // fetchMetadata stays empty -> verify fails
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(store.uploadCalls.count, 2, "items upload...")
        let loaded = await MigrationPlanStore(album: album).load()
        let plan = try XCTUnwrap(loaded)
        XCTAssertTrue(plan.items.allSatisfy { $0.state != .sourceDeleted }, "...but none are deleted without verification")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "the local original survives a failed verification")
        }
        if case .failed = manager.state {} else { XCTFail("expected a failed run, got \(manager.state)") }
    }

    func testMigrationPreservesPreviewsInGlobalThumbnailDirectory() async throws {
        // Previews live in the single global, storage-agnostic thumbnail
        // directory; the `.cloudKit` twin reads them from exactly the same path.
        // Deleting them with the source ciphertext forces a full thumbnail
        // re-download of a just-migrated album (blank grid cells offline), and
        // for a Live Photo removes the shared preview before its second
        // component uploads.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let model = album.storageOption.modelForType.init(album: album)
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: model.previewURLForMedia(withID: id).path),
                          "precondition: seeding produced a preview")
        }

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: model.previewURLForMedia(withID: id).path),
                          "the preview survives the move — the migrated album reads it from the same global path")
            try? FileManager.default.removeItem(at: model.previewURLForMedia(withID: id))
        }
    }

    func testReRunAfterCompletionDoesNotReUpload() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)
        XCTAssertEqual(store.uploadCalls.count, 2)
        XCTAssertEqual(albumManager.finalizeCallCount, 1)

        // A second run (e.g. the user re-opens the screen): the source is already
        // drained, so nothing re-uploads and the album isn't flipped again.
        await manager.start(album: album)
        XCTAssertEqual(store.uploadCalls.count, 2, "completed items are never re-uploaded")
        XCTAssertEqual(albumManager.finalizeCallCount, 1, "the album is not re-finalized")
    }

    func testResumingAnAlreadyUploadedItemVerifiesWithoutReUploading() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        let id = try XCTUnwrap(ids.first)
        let planned = try await manager.plan(album: album)
        let item = try XCTUnwrap(planned.items.first)

        // Simulate a crash AFTER the upload reached CloudKit but BEFORE the source was
        // deleted: the record is on the server and the checkpoint says `uploaded`.
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName, albumID: "x", mediaID: item.mediaID, mediaType: item.mediaType,
            createdAt: item.createdAt, sizeBytes: item.sizeBytes, creationDeviceID: "mock",
            schemaVersion: 1, recordChangeTag: "tag"
        )]
        let planStore = MigrationPlanStore(album: album)
        let loaded = await planStore.load()
        var persisted = try XCTUnwrap(loaded)
        persisted.items[0].state = .uploaded
        try await planStore.save(persisted)

        await manager.start(album: album)

        XCTAssertTrue(store.uploadCalls.isEmpty, "an already-uploaded item is verified, not re-uploaded")
        XCTAssertEqual(manager.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
    }

    // MARK: - Parent reference ordering

    func testAlbumRecordIsSavedBeforeAnyUpload() async throws {
        // CloudKit rejects a media save whose parent `EncAlbum` record is not on
        // the server (CKError 31, reference violation). With the mock enforcing
        // that requirement, this run completes only because `run` creates the
        // album record before the item loop — the 2b4ab4f4 fix.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.enforceParentAlbumExists = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(store.savedAlbumCalls.count, 1, "the album record is created up front, before the item loop")
        XCTAssertEqual(manager.state, .completed,
                       "uploads succeed because the parent album record already exists on the server")
        XCTAssertEqual(store.uploadCalls.count, 2)
    }

    // MARK: - Key fingerprint

    func testMigratedMediaIsStampedWithTheAlbumKeyFingerprint() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(store.uploadedItems.count, 2)
        for upload in store.uploadedItems {
            XCTAssertEqual(upload.keyFingerprint, album.key.keychainLabel,
                           "every migrated record must name the key that encrypted it")
        }
        XCTAssertEqual(store.savedAlbumCalls.first?.keyFingerprint, album.key.keychainLabel,
                       "and the album record agrees with its media")
        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 2, fingerprints: [album.key.keychainLabel: 2]),
                       "so the census can name the key for the whole migrated library")
    }

    func testSaveAlbumFailureFailsFastWithoutUploading() async throws {
        // If the album record cannot be created, every upload would fail with the
        // same reference violation — the run must fail fast with the real reason
        // instead of emitting N identical per-item failures.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.saveAlbumError = CloudKitMediaStoreError.zoneNotFound
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertTrue(store.uploadCalls.isEmpty, "no uploads are attempted without the parent album record")
        guard case .failed(.other) = manager.state else {
            return XCTFail("expected a failed run carrying the saveAlbum error, got \(manager.state)")
        }
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "nothing is deleted when the run fails before uploading")
        }
    }

    func testSaveAlbumSchemaMissingSurfacesSchemaNotDeployedReason() async throws {
        // A release build whose CloudKit Production schema lacks the `EncAlbum`
        // record type fails the very first `saveAlbum` with a per-record
        // `CKError.invalidArguments` ("Cannot create new type EncAlbum in
        // production schema"). That must surface as the distinct
        // `.schemaNotDeployed` reason — not the generic
        // `.other("Partial failure (1 failed)")` — so the alert is actionable
        // and the diagnostic shorthand names the real cause.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        let serverError = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.invalidArguments.rawValue,
            userInfo: ["ServerErrorDescription": "Cannot create new type EncAlbum in production schema"]
        )
        store.saveAlbumError = CloudKitMediaStoreError.partial(failed: ["albumhash": serverError])
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertTrue(store.uploadCalls.isEmpty, "no uploads are attempted without the parent album record")
        XCTAssertEqual(manager.state, .failed(.schemaNotDeployed))
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "nothing is deleted when the run fails before uploading")
        }
    }

    // MARK: - Errors, pause, cancel

    func testRetryAfterBacksOffThenSucceeds() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.retry(after: 0)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(store.uploadCalls.count, 2, "one retried attempt then a success")
    }

    func testQuotaExceededHaltsThenResumeCompletes() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.quotaExceeded
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .failed(.quota), "quota is non-retryable: the run halts, recoverable")
        let midLoaded = await MigrationPlanStore(album: album).load()
        let mid = try XCTUnwrap(midLoaded)
        XCTAssertFalse(mid.items.contains { $0.state == .sourceDeleted }, "nothing deleted while halted")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
        }

        // "Free up space" (the one-shot error already cleared) and resume.
        await manager.resume(album: album)
        XCTAssertEqual(manager.state, .completed)
        XCTAssertFalse(MigrationPlanStore.hasPlan(for: album), "the checkpoint is removed on completion")
        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
        }
    }

    func testQuotaWrappedInPartialFailureStillHaltsAsQuota() async throws {
        // The real adapter reports a CKModifyRecordsOperation's per-record failure
        // wrapped in `.partialFailure` -> `.partial(failed:)`. The quota halt must
        // fire through that wrapping, not just for the bare typed error.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.partial(
            failed: ["some-record": CKErrorFactory.error(.quotaExceeded)]
        )
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .failed(.quota), "a partial-wrapped quota failure must halt as quota")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
        }
    }

    func testConflictWrappedInPartialFallsThroughToVerify() async throws {
        // A record with the stable name already on the server surfaces as a
        // partial-wrapped `.serverRecordChanged`. The engine must fall through to
        // the verify gate (which confirms presence + size) instead of failing.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        let plan = try await manager.plan(album: album)
        let item = try XCTUnwrap(plan.items.first)
        // Server truth: the record is already there with the expected size.
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName,
            albumID: "any",
            mediaID: item.mediaID,
            mediaType: item.mediaType,
            createdAt: item.createdAt,
            sizeBytes: item.sizeBytes,
            creationDeviceID: "other-device",
            schemaVersion: CloudKitSchema.currentSchemaVersion,
            recordChangeTag: "tag-existing"
        )]
        store.uploadErrorOnce = CloudKitMediaStoreError.partial(
            failed: [item.recordName: CKErrorFactory.error(.serverRecordChanged)]
        )

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "an already-on-server record must verify and complete, not wedge as failed")
    }

    func testStaleVerifiedItemIsReVerifiedBeforeSourceDelete() async throws {
        // An item persisted as `verified` from an earlier run may be arbitrarily
        // stale — the record could have been erased from another device since.
        // Resume must re-verify before the irreversible source delete.
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        var plan = try await manager.plan(album: album)
        for index in plan.items.indices { plan.items[index].state = .verified }
        try await MigrationPlanStore(album: album).save(plan)

        // Server truth: the record no longer exists (metadataToReturn stays empty),
        // and the re-driven upload cannot verify either (`reflectUploadsInMetadata`
        // is off) — so the item must surface as a visible failure, not a silent
        // `.idle` the launcher reads as a user cancel.
        await manager.start(album: album)

        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "a stale verification must never justify deleting the local original")
        }
        let reloadedPlan = await MigrationPlanStore(album: album).load()
        let reloaded = try XCTUnwrap(reloadedPlan)
        XCTAssertTrue(reloaded.items.allSatisfy { $0.state == .failed },
                      "an item that cannot re-verify is failed (resumable: re-plan resets failed to pending)")
        guard case .failed = manager.state else {
            return XCTFail("expected a visible .failed run, got \(manager.state)")
        }
    }

    func testStaleVerifiedItemIsReDrivenToCompletionInSamePass() async throws {
        // A stale `verified` item whose record vanished is reset to `pending` by
        // the re-verify gate. The run must re-drive it in the SAME pass (upload,
        // verify, delete) and complete — not end as a silent `.idle` that the
        // launcher reports to the user as "Move to iCloud canceled".
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        var plan = try await manager.plan(album: album)
        for index in plan.items.indices { plan.items[index].state = .verified }
        try await MigrationPlanStore(album: album).save(plan)

        // Server truth: the record is gone (metadataToReturn starts empty), but a
        // re-upload will land and verify.
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "the re-driven item must finish in this pass")
        XCTAssertEqual(store.uploadCalls.count, 1, "the vanished record is re-uploaded exactly once")
        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                           "the source is deleted only after the fresh upload re-verified")
        }
    }

    func testUnwrapPartialUnwrapsSingleAndHomogeneousErrors() {
        let single = CloudKitMigrationManager.unwrapPartial(
            .partial(failed: ["r1": CKErrorFactory.error(.quotaExceeded)])
        )
        guard case .quotaExceeded = single else { return XCTFail("single-record partial must unwrap, got \(single)") }

        let homogeneous = CloudKitMigrationManager.unwrapPartial(
            .partial(failed: ["r1": CKErrorFactory.error(.quotaExceeded),
                              "r2": CKErrorFactory.error(.quotaExceeded)])
        )
        guard case .quotaExceeded = homogeneous else { return XCTFail("homogeneous partial must unwrap, got \(homogeneous)") }

        let mixed = CloudKitMigrationManager.unwrapPartial(
            .partial(failed: ["r1": CKErrorFactory.error(.quotaExceeded),
                              "r2": CKErrorFactory.error(.serverRecordChanged)])
        )
        guard case .partial = mixed else { return XCTFail("heterogeneous partial must stay partial, got \(mixed)") }
    }

    func testMigrationFailsClosedWhenAlbumIDHashCannotBeDerived() async throws {
        // If the keyed-hash derivation fails, the run must fail closed: falling
        // back to `album.id` ("<name>_<storage>") would persist the CLEARTEXT
        // album name into CloudKit record fields — and in a namespace the
        // reconciler (which skips unhashable albums) can never match, pull, or
        // tombstone.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        manager.albumIDHashOverride = { _ in nil }   // derivation failure
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        guard case .failed = manager.state else {
            return XCTFail("expected the run to fail closed, got \(manager.state)")
        }
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "no album record may be written under a cleartext-derived id")
        XCTAssertTrue(store.uploadCalls.isEmpty, "no media may be uploaded under a cleartext-derived id")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "nothing is deleted when the run fails before uploading")
        }
    }

    func testAccountUnavailableFailsRunWithoutUploading() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.accountAvailableValue = false
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .failed(.accountUnavailable))
        XCTAssertTrue(store.uploadCalls.isEmpty, "no uploads are attempted without an account")
    }

    func testCancelRevertsInFlightItemAndStaysUsable() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        // Simulate a crash mid-upload: the checkpoint shows an `uploading` item.
        let planStore = MigrationPlanStore(album: album)
        let loaded = await planStore.load()
        var persisted = try XCTUnwrap(loaded)
        persisted.items[0].state = .uploading
        try await planStore.save(persisted)

        await manager.cancel(album: album)

        XCTAssertEqual(manager.state, .idle)
        let revertedLoad = await planStore.load()
        let reverted = try XCTUnwrap(revertedLoad)
        XCTAssertEqual(reverted.items[0].state, .pending, "an in-flight item is reverted so a resume re-drives it")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "cancel never deletes a source file")
        }
    }

    func testCancelIsDurableAndNotAutoResumed() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        albumManager.albumsOnDisk = [album]
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)
        let pendingBeforeCancel = await manager.pendingPlans()
        XCTAssertEqual(pendingBeforeCancel.map(\.id), [album.id],
                       "an incomplete plan is resumable before it is cancelled")

        await manager.cancel(album: album)

        let persisted = await MigrationPlanStore(album: album).load()
        XCTAssertNotNil(persisted?.cancelledAt, "an explicit cancel is recorded durably on the checkpoint")
        let pendingAfterCancel = await manager.pendingPlans()
        XCTAssertTrue(pendingAfterCancel.isEmpty,
                      "a cancelled migration is never silently auto-resumed on the next launch")
    }

    func testCancelDuringPreflightIsHonoredBeforeAnyUpload() async throws {
        // The launcher registers its cancellation handler as soon as the task is
        // added, so a cancel can land while `start()` is still planning or inside
        // the account/zone/saveAlbum preflight. It must stop the run before the
        // first upload — not be clobbered by the run loop claiming `control`.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        store.accountAvailableGate = { [weak manager] in
            await manager?.cancel(album: album)
        }
        await manager.start(album: album)

        XCTAssertTrue(store.uploadCalls.isEmpty, "no upload may start after an explicit cancel")
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: ids[0]).path),
                      "the local original is untouched")
        let plan = await MigrationPlanStore(album: album).load()
        XCTAssertNotNil(plan?.cancelledAt, "the cancel must be durable so background auto-resume skips it")
    }

    func testCancelDuringPreflightOfEmptyAlbumDoesNotFinalize() async throws {
        // The zero-item plan never enters the item loop, so the pre-loop control
        // check is the only thing standing between a cancelled preflight and an
        // album silently flipped to CloudKit.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 0, albumManager: albumManager, album: album)
        store.accountAvailableGate = { [weak manager] in
            await manager?.cancel(album: album)
        }
        await manager.start(album: album)

        XCTAssertEqual(albumManager.finalizeCallCount, 0,
                       "an explicit cancel must not flip the album to CloudKit")
        XCTAssertEqual(manager.state, .idle)
    }

    func testMissingSourceFileDoesNotWedgeMigration() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)
        // One source ciphertext disappears out of band before the migration runs.
        try FileManager.default.removeItem(at: sourceEncURL(album: album, id: ids[0]))

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed,
                       "a single missing file must not block the album short of completion")
        XCTAssertEqual(albumManager.finalizeCallCount, 1, "the album still flips to CloudKit")
        XCTAssertEqual(store.uploadCalls.count, 1, "only the file that still exists is uploaded")
    }

    func testEmptyAlbumMigrationFinalizesAndCompletes() async throws {
        // Zero items means zero remaining work, not "incomplete": the run must
        // finalize (flip the album to CloudKit) and clean up its checkpoint, not
        // fall into `.idle` and orphan a never-resumable zero-item plan.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 0, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "an empty album must complete, not wedge as .idle")
        XCTAssertEqual(albumManager.finalizeCallCount, 1, "the empty album still flips to CloudKit")
        XCTAssertFalse(MigrationPlanStore.hasPlan(for: album), "no orphaned zero-item checkpoint is left behind")
        XCTAssertTrue(store.uploadCalls.isEmpty)
    }

    func testPlanDoesNotPublishTerminalCompleted() async throws {
        // Planning must never publish a terminal state: on a finalize-retry resume
        // (all items already sourceDeleted) a pre-run `.completed` makes the UI
        // adopt the CloudKit twin and tear down its binding BEFORE `run()` retries
        // finalize — dropping the failure if finalize fails again.
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        let planStore = MigrationPlanStore(album: album)
        let loaded = await planStore.load()
        var persisted = try XCTUnwrap(loaded)
        for index in persisted.items.indices { persisted.items[index].state = .sourceDeleted }
        try await planStore.save(persisted)

        _ = try await manager.plan(album: album)
        XCTAssertNotEqual(manager.state, .completed,
                          "plan() must leave terminal states to run()")
    }

    // MARK: - Estimate (pre-flight)

    func testEstimateReturnsCountsWithoutPersistingCheckpoint() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let estimate = await manager.estimate(album: album)

        XCTAssertEqual(estimate.itemCount, 2)
        XCTAssertGreaterThan(estimate.totalBytes, 0)
        XCTAssertFalse(MigrationPlanStore.hasPlan(for: album),
                       "previewing the estimate must not leave a checkpoint that could auto-resume")
    }

    func testEstimateIsZeroForCloudKitAlbum() async {
        let album = makeAlbum(storage: .cloudKit)
        let (manager, _, _) = makeExecutableManager(for: album)
        let estimate = await manager.estimate(album: album)
        XCTAssertEqual(estimate.itemCount, 0)
        XCTAssertEqual(estimate.totalBytes, 0)
    }

    // MARK: - Launch-time resume

    func testPendingPlansSurfacesIncompleteMigration() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        albumManager.albumsOnDisk = [album]
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)   // writes an incomplete checkpoint

        let pending = await manager.pendingPlans()
        XCTAssertEqual(pending.map(\.id), [album.id])
    }

    func testPendingPlansEmptyWhenNoCheckpoint() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        albumManager.albumsOnDisk = [album]
        defer { cleanup(album) }

        let pending = await manager.pendingPlans()
        XCTAssertTrue(pending.isEmpty)
    }

    func testFinalizeFailureKeepsCheckpointSurfacedByPendingPlans() async throws {
        // Finalize failure leaves every item `sourceDeleted` (no remaining per-item
        // work) but the album undiscoverable — the checkpoint is the ONLY retry
        // state. `pendingPlans()` must surface it, or the one-time failure alert is
        // the last chance anyone gets to retry finalize.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        albumManager.albumsOnDisk = [album]
        albumManager.finalizeError = AlbumError.cloudKitMarkerWriteFailed
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        guard case .failed = manager.state else {
            return XCTFail("finalize failure must fail the run, got \(manager.state)")
        }
        XCTAssertTrue(MigrationPlanStore.hasPlan(for: album), "the checkpoint is kept for retry")

        let pending = await manager.pendingPlans()
        XCTAssertEqual(pending.map(\.id), [album.id],
                       "a finalize-pending checkpoint has no remaining per-item work, but it IS unfinished business")
    }

    func testFinalizeFailureCheckpointResumesToCompletion() async throws {
        // The kept checkpoint must actually finish the job on the next resume once
        // the failure clears: retry finalize, flip the album, delete the checkpoint.
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        albumManager.albumsOnDisk = [album]
        albumManager.finalizeError = AlbumError.cloudKitMarkerWriteFailed
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)
        albumManager.finalizeError = nil

        await manager.resume(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(albumManager.finalizeCallCount, 2, "the resume retried finalize")
        XCTAssertFalse(MigrationPlanStore.hasPlan(for: album), "completion deletes the checkpoint")
        XCTAssertEqual(store.uploadCalls.count, 1, "the resume must not re-upload the already-verified item")
    }

    func testPendingPlansEmptyAfterCompletion() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        albumManager.albumsOnDisk = [album]
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        let pending = await manager.pendingPlans()
        XCTAssertTrue(pending.isEmpty, "a completed migration leaves no checkpoint to resume")
    }

    // MARK: - AlbumManager integration

    func testMoveAlbumToCloudKitIsRejectedInFavorOfMigration() throws {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let album = makeAlbum()
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        XCTAssertThrowsError(try manager.moveAlbum(album: album, toStorage: .cloudKit)) { error in
            guard case AlbumError.migrationRequiredForCloudKit = error else {
                return XCTFail("expected migrationRequiredForCloudKit, got \(error)")
            }
        }
    }

    /// Moving media into the cloud must never be treated as consent to sync the
    /// key that decrypts it. A full local -> CloudKit migration leaves the key
    /// sync setting exactly as the user left it (ENC-84).
    func testMigrationDoesNotTouchKeySyncSetting() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let keyManager = albumManager.keyManager as! DemoKeyManager
        keyManager.isSyncEnabled = false

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "precondition: the migration actually ran")
        XCTAssertFalse(keyManager.isSyncEnabled, "a migration must not enable key sync as a side effect")
    }

    func testMoveCloudKitAlbumToLocalAbortsWhenReconcileFails() async throws {
        // Every destructive step of the move (export, deleteAllMedia, tombstone)
        // enumerates from the LOCAL index. If the pre-move reconcile fails, that
        // index may be stale or empty (fresh device), so tearing down the cloud
        // plane would orphan every record the index doesn't know about — on every
        // device. The move must abort and leave the album fully usable in CloudKit.
        let priorMakeStore = CloudKitStoreProvider.makeStore
        let store = MockCloudKitMediaStore()
        store.fetchChangesError = CloudKitMediaStoreError.underlying(NSError(domain: "test", code: 1))
        CloudKitStoreProvider.makeStore = { _ in store }
        defer { CloudKitStoreProvider.makeStore = priorMakeStore }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        var album = makeAlbum()
        album.storageOption = .cloudKit
        defer { cleanup(album) }

        do {
            _ = try await manager.moveCloudKitAlbumToLocal(album: album)
            XCTFail("a failed reconcile must abort the move, not run the cloud teardown against a stale index")
        } catch {
            // Any thrown error is acceptable; the teardown assertions below are the contract.
        }
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty,
                      "the album record must not be deleted after a failed reconcile")
        XCTAssertTrue(store.deleteCalls.isEmpty,
                      "no media record may be touched after a failed reconcile")
    }

    func testFinalizeWritesDiscoveryMarkerAndRemovesSource() throws {
        // Finalize pushes the album record via the global store provider, and with
        // `cloudKitStorage` defaulting ON in DEBUG the real provider constructs a
        // live CKContainer — which aborts the bare xctest process (no CloudKit
        // entitlement). Bind the in-memory mock for the duration of this test.
        let priorMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in InMemoryCloudKitMediaStore() }
        defer { CloudKitStoreProvider.makeStore = priorMakeStore }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        let result = try manager.finalizeMigrationToCloudKit(album: album)
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(result.encryptedPathComponent)
        defer { try? FileManager.default.removeItem(at: marker) }

        XCTAssertEqual(result.storageOption, .cloudKit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.baseURL.path), "the drained source dir is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the CloudKit discovery marker is written")
    }

    // MARK: - iCloud Drive deprecation is unconditional (ENC-88)

    /// Both deprecation backstops used to be gated on the `cloudKitStorage` feature
    /// flag, which defaults ON only in DEBUG — so in a release build they were inert
    /// and iCloud Drive albums kept being created. These two tests drive the gates
    /// with the flag explicitly OFF, which is precisely the release configuration.

    func testCreateICloudDriveAlbumThrowsInAllBuildConfigurations() throws {
        let prior = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: prior) }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        XCTAssertThrowsError(
            try manager.create(name: "drive-\(UUID().uuidString)", storageOption: .icloud)
        ) { error in
            guard case AlbumError.iCloudDriveDeprecated = error else {
                return XCTFail("expected iCloudDriveDeprecated, got \(error)")
            }
        }
    }

    func testMoveToICloudDriveThrowsInAllBuildConfigurations() throws {
        let prior = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: prior) }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        // The album is laid down on disk so the source-existence check passes: the
        // throw has to come from the deprecation gate, not from a missing directory,
        // or this would pass for the wrong reason.
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer { cleanup(album) }

        XCTAssertThrowsError(try manager.moveAlbum(album: album, toStorage: .icloud)) { error in
            guard case AlbumError.iCloudDriveDeprecated = error else {
                return XCTFail("expected iCloudDriveDeprecated, got \(error)")
            }
        }
    }

    /// The deprecation must not hand a `.icloud` default back to the picker-less
    /// quick-create paths, which would walk straight into the create backstop.
    func testPersistedICloudDefaultIsCoercedToLocal() throws {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        let prior = manager.defaultStorageForAlbum
        defer { manager.defaultStorageForAlbum = prior }

        manager.defaultStorageForAlbum = .icloud
        XCTAssertEqual(manager.defaultStorageForAlbum, .local)
    }

    /// Deprecation must stop iCloud Drive being OFFERED, never stop what is already
    /// there being SEEN. If enumeration were gated on `isStorageTypeOfferedForNewAlbums`
    /// (which reports `.icloud` unavailable unconditionally) instead of
    /// `isStorageTypeAvailable`, a user's existing Drive albums would silently vanish
    /// from the grid — unusable and unmigratable, since the migration prompt can only
    /// offer what it can find.
    func testICloudDriveAlbumsRemainEnumerableWhileDeprecated() async throws {
        XCTAssertNotEqual(DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud), .available,
                          "precondition: iCloud Drive is never offered as a destination")

        try await withICloudDriveRoot {
            XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud), .available,
                           "but an existing container is still readable")

            let keyManager = DemoKeyManager()
            let key = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
            keyManager.currentKey = key
            let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

            let legacy = Album(name: "legacy-\(UUID().uuidString)", storageOption: .icloud,
                               creationDate: Date(), key: key)
            try iCloudStorageModel(album: legacy).initializeDirectories()
            defer { cleanup(legacy) }

            let found = manager.fetchAlbumsFromSources(includingHidden: true)
            let match = try XCTUnwrap(found.first { $0.name == legacy.name },
                                      "an existing iCloud Drive album must still appear in the grid")
            XCTAssertEqual(match.storageOption, .icloud,
                           "and must keep its real storage type, so the migration prompt can find it")
        }
    }

    /// Deferring the migration prompt is a per-device decision: another device may
    /// not even hold the legacy albums, so syncing the dismissal would silently
    /// suppress the prompt where it still applies.
    func testMigrationPromptDismissalIsDeviceLocal() {
        XCTAssertFalse(UserDefaultKey.dismissediCloudDriveMigrationPrompt.shouldSyncToiCloud)
    }

    // MARK: - iCloud Drive (legacy) source

    /// Points `iCloudStorageModel` at a scratch directory for the duration of a test.
    /// Neither the simulator nor a unit-test host has a ubiquity container, so without
    /// this the `.icloud` source path cannot be executed at all — `rootURL` traps.
    /// Everything downstream of `albumManager.storageModel(for:)` is unchanged, and
    /// that single seam is what the engine drives the source through, so these tests
    /// exercise the real `.icloud` code path rather than a re-labelled local one.
    private func withICloudDriveRoot(_ body: () async throws -> Void) async rethrows {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("icloud-drive-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = root
        defer {
            iCloudStorageModel.testContainerRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    /// Planning must enumerate a legacy iCloud Drive album exactly as it does a local
    /// one — the engine accepts `.icloud`, but until now only `.local` had ever been
    /// executed end to end.
    func testPlanFromICloudDriveSourceEnumeratesAllItems() async throws {
        try await withICloudDriveRoot {
            let album = makeAlbum(storage: .icloud)
            let (manager, albumManager) = makeManager(for: album)
            defer { cleanup(album) }

            let ids = try await seedLocalAlbum(count: 3, albumManager: albumManager, album: album)
            let plan = try await manager.plan(album: album)

            XCTAssertEqual(plan.sourceStorage, .icloud)
            XCTAssertEqual(plan.items.count, 3, "every component of an iCloud Drive album becomes a work item")
            XCTAssertEqual(Set(plan.items.map(\.mediaID)), Set(ids))
            XCTAssertTrue(plan.items.allSatisfy { $0.state == .pending })
            XCTAssertTrue(plan.items.allSatisfy { $0.sizeBytes > 0 },
                          "sizes are read from the iCloud Drive container, not assumed")
        }
    }

    /// The verification gate must hold for an iCloud Drive source too: if the record
    /// cannot be confirmed in CloudKit, the Drive original is never removed. This is
    /// the only copy of the user's data at that moment, so a source-agnostic delete
    /// would be silent data loss.
    func testICloudDriveSourceRemovedOnlyAfterVerification() async throws {
        try await withICloudDriveRoot {
            let album = makeAlbum(storage: .icloud)
            let (manager, albumManager, store) = makeExecutableManager(for: album)
            store.reflectUploadsInMetadata = false   // verification can never succeed
            defer { cleanup(album) }

            let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
            await manager.start(album: album)

            XCTAssertEqual(store.uploadCalls.count, 2, "items upload...")
            let loaded = await MigrationPlanStore(album: album).load()
            let plan = try XCTUnwrap(loaded)
            XCTAssertTrue(plan.items.allSatisfy { $0.state != .sourceDeleted },
                          "...but no item advances past verification")
            for id in ids {
                XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                              "the iCloud Drive original survives a failed verification")
            }
            XCTAssertEqual(albumManager.finalizeCallCount, 0, "and the album is not flipped to CloudKit")
            if case .failed = manager.state {} else { XCTFail("expected a failed run, got \(manager.state)") }

            // Now let verification succeed and resume: the same sources ARE removed,
            // which proves the assertions above are gated on verification and not on
            // the `.icloud` source being skipped wholesale.
            store.reflectUploadsInMetadata = true
            await manager.start(album: album)

            XCTAssertEqual(manager.state, .completed)
            for id in ids {
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                               "once verified, the iCloud Drive original is removed")
            }
        }
    }

    /// A migration killed mid-flight resumes from its checkpoint on the next launch,
    /// mirroring the existing `.local` resume coverage.
    func testInterruptedICloudDriveMigrationResumes() async throws {
        try await withICloudDriveRoot {
            let album = makeAlbum(storage: .icloud)
            let (manager, albumManager, store) = makeExecutableManager(for: album)
            albumManager.albumsOnDisk = [album]
            store.reflectUploadsInMetadata = true
            defer { cleanup(album) }

            let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
            let planned = try await manager.plan(album: album)
            XCTAssertEqual(planned.items.count, 2)

            // Simulate a kill after the first item finished and before the second
            // started, by writing that exact checkpoint back to disk.
            let planStore = MigrationPlanStore(album: album)
            let loaded = await planStore.load()
            var persisted = try XCTUnwrap(loaded)
            persisted.items[0].state = .sourceDeleted
            try await planStore.save(persisted)
            try FileManager.default.removeItem(at: sourceEncURL(album: album, id: persisted.items[0].mediaID))

            let pending = await manager.pendingPlans()
            XCTAssertEqual(pending.map(\.id), [album.id],
                           "the interrupted iCloud Drive migration is surfaced for resume on launch")

            await manager.start(album: album)

            XCTAssertEqual(manager.state, .completed)
            XCTAssertEqual(store.uploadCalls.count, 1,
                           "only the item that had not finished is uploaded on resume")
            XCTAssertEqual(albumManager.finalizeCallCount, 1)
            for id in ids {
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
            }
            XCTAssertFalse(MigrationPlanStore.hasPlan(for: album), "the checkpoint is cleared on completion")
        }
    }

    // MARK: - Published phase (ENC-121)

    /// Records every `progress` snapshot published while `body` runs. Everything here
    /// is main-actor isolated and the run is awaited, so the sink fires synchronously
    /// on each assignment and the recorded order is the published order.
    private func recordingProgress(
        of manager: CloudKitMigrationManager,
        during body: () async -> Void
    ) async -> [MigrationProgress] {
        var seen: [MigrationProgress] = []
        let subscription = manager.$progress.sink { seen.append($0) }
        await body()
        subscription.cancel()
        return seen
    }

    func testPhaseAdvancesUploadingVerifyingRemovingAcrossOneItem() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)

        let seen = await recordingProgress(of: manager) { await manager.start(album: album) }
        XCTAssertEqual(manager.state, .completed)

        // Collapse runs of the same phase: the assertion is about the ORDER of the
        // transitions, not how many snapshots each one happened to produce.
        let phases = seen.map(\.phase).reduce(into: [MigrationPhase?]()) { acc, phase in
            if acc.last != phase { acc.append(phase) }
        }

        XCTAssertEqual(phases.compactMap { $0 },
                       [.preparing, .uploading, .verifying, .removingLocalCopy],
                       "the published phase must walk the item's real transitions in order")
    }

    func testPhasePersistsAcrossTheBetweenItemProgressRepublish() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)

        let seen = await recordingProgress(of: manager) { await manager.start(album: album) }
        XCTAssertEqual(manager.state, .completed)

        let phases = seen.map(\.phase)
        let firstActive = try XCTUnwrap(phases.firstIndex(where: { $0 != nil }))
        let lastActive = try XCTUnwrap(phases.lastIndex(where: { $0 != nil }))

        // `run()` rebuilds `progress` wholesale before and after every item. If those
        // rebuilds bypassed the funnel, the phase would drop to nil between items.
        XCTAssertFalse(phases[firstActive...lastActive].contains(nil),
                       "no nil phase may be published between the first and last active phase — that is the clobber this guards")
    }

    func testPhaseIsClearedOnCompletion() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertNil(manager.progress.phase, "a completed migration must not still claim a phase")
    }

    func testPhaseIsClearedOnCancel() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        await manager.cancel(album: album)

        XCTAssertNil(manager.progress.phase, "a cancelled migration must not still claim a phase")
    }

    func testPhaseIsClearedWhenAQuotaFailureHaltsTheRun() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.quotaExceeded
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .failed(.quota))
        XCTAssertNil(manager.progress.phase, "a halted migration must not still claim a phase")
    }

    func testRetryingPhaseIsPublishedDuringBackoff() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.retry(after: 0)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)

        let seen = await recordingProgress(of: manager) { await manager.start(album: album) }

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(store.uploadCalls.count, 2, "one retried attempt then a success")
        XCTAssertTrue(seen.contains { $0.phase == .retrying },
                      "a CloudKit-requested backoff must be visible as .retrying, not an unexplained stall")
        XCTAssertNil(manager.progress.phase)
    }

    /// The phase is in-memory only. `MigrationPlan` is a durable on-disk format, and a
    /// phase written into it would be a lie after a crash.
    func testMigrationPlanEncodingIsUnchangedByPhase() throws {
        let plan = MigrationPlan(
            albumName: "album",
            sourceStorage: .local,
            items: [MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10)],
            createdAt: Date()
        )

        let encoded = try JSONEncoder().encode(plan)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["albumName", "sourceStorage", "items", "createdAt", "version"],
                       "the checkpoint's key set must not change — `phase` is never persisted")

        let itemObjects = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertFalse(itemObjects.contains { $0.keys.contains("phase") },
                       "items must not carry a phase either")

        // And it still round-trips.
        let decoded = try JSONDecoder().decode(MigrationPlan.self, from: encoded)
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.version, MigrationPlan.currentVersion)
    }

    // MARK: - CloudKit -> local move progress

    /// The full round trip against ONE shared in-memory store: the forward engine
    /// lands a real album in "CloudKit", then the reverse move drains it back while
    /// reporting `CloudToLocalMoveProgress` — the sequence the blocking overlay
    /// renders, so the phase order and count monotonicity are the contract.
    func testMoveCloudKitAlbumToLocalReportsPhasesAndMonotonicCounts() async throws {
        // One store for both directions: the engine uploads into it (storeFactory)
        // and the reverse move's reconcile/export/teardown read the same records
        // back out through the global provider.
        let shared = InMemoryCloudKitMediaStore()
        let priorMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer { CloudKitStoreProvider.makeStore = priorMakeStore }

        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let mockAlbumManager = MockAlbumManager(keyManager: keyManager)
        mockAlbumManager.albumsOnDisk = [album]
        let engine = CloudKitMigrationManager(albumManager: mockAlbumManager, storeFactory: { _ in shared })
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 3, albumManager: mockAlbumManager, album: album)
        await engine.start(album: album)
        XCTAssertEqual(engine.state, .completed,
                       "precondition: the forward migration must land the album in CloudKit")

        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        let recorder = CloudToLocalProgressRecorder()
        let moved = try await manager.moveCloudKitAlbumToLocal(album: Album.cloudKitTwin(of: album)) { snapshot in
            await recorder.record(snapshot)
        }
        XCTAssertEqual(moved.storageOption, .local, "a completed move hands back the flipped .local album")

        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots.first?.phase, .preparing,
                       "the move must announce itself before the reconcile, so the overlay covers the grid immediately")
        XCTAssertEqual(snapshots.last?.phase, .removingRemoteCopy,
                       "the final report is the cloud-plane teardown — nothing may be published after it")

        let downloading = snapshots.filter { $0.phase == .downloading }
        XCTAssertEqual(downloading.first?.exportedCount, 0,
                       "the export announces its total before the first item, so the overlay shows 0/N not a blank")
        XCTAssertEqual(downloading.last?.exportedCount, 3, "every seeded component must report as exported")
        XCTAssertTrue(downloading.allSatisfy { $0.totalCount == 3 },
                      "the total must hold steady across the run; got \(downloading.map(\.totalCount))")
        let counts = downloading.map(\.exportedCount)
        XCTAssertEqual(counts, counts.sorted(),
                       "exported counts must never go backwards; got \(counts)")
    }
}

/// Serializes `CloudToLocalMoveProgress` snapshots from the move's `@Sendable`
/// callback; each report is awaited by the move, so the recorded order is the
/// published order.
private actor CloudToLocalProgressRecorder {
    private(set) var snapshots: [CloudToLocalMoveProgress] = []
    func record(_ snapshot: CloudToLocalMoveProgress) { snapshots.append(snapshot) }
}
