//
//  ICloudDriveMigrationTests.swift
//  EncameraCoreTests
//
//  The engine's contract for migrating an iCloud Drive album to CloudKit.
//
//  iCloud Drive was closed as a destination without anything that actually moves
//  the files: the prompt on the album grid led to a flow that threw. The engine now
//  accepts an `.icloud` source and materializes evicted files a batch at a time
//  before uploading them, so from the uploader's point of view a Drive file is
//  indistinguishable from a local one.
//
//  The failure mode these tests exist to prevent: an evicted file enumerates as a
//  `.icloud` placeholder, so the materialized path the uploader wants does not
//  exist. The old source check called that "nothing to migrate" and marked the item
//  `.skipped`, which is TERMINAL and counts as done — the album would finalize,
//  flip to CloudKit, and leave the user's photo behind in iCloud Drive with no
//  record of it anywhere. `testFailedDownloadFailsTheItemRatherThanSkippingIt` is
//  the test that goes red if that ever comes back.
//
//  These are mocked, and mocked in the one place that matters least: the fake
//  materializer replaces Apple's download observation wholesale. They are a
//  regression net, not proof the feature works.
//

import XCTest
import UIKit
@testable import EncameraCore

@MainActor
final class ICloudDriveMigrationTests: XCTestCase {

    // MARK: - Fixtures

    private var containerRoot: URL?

    override func tearDown() {
        if let containerRoot {
            try? FileManager.default.removeItem(at: containerRoot)
        }
        iCloudStorageModel.testContainerRootOverride = nil
        ICloudPlaceholderName.testEvictedURLs = nil
        containerRoot = nil
        UserDefaultUtils.set(0, forKey: .iCloudDriveMigrationBatchSize)
        try? MediaIndexStore.clearAllIndexes()
        super.tearDown()
    }

    /// Substitutes the ubiquity container root, the same seam
    /// `ICloudDriveLegacyContractTests` uses. Only the root is faked; everything
    /// below it is the real `.icloud` code path.
    private func useScratchContainer() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("icloud-migration-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = root
        containerRoot = root
    }

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeDriveAlbum() -> Album {
        let key = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        return Album(name: "drive-\(UUID().uuidString)", storageOption: .icloud,
                     creationDate: Date(), key: key)
    }

    private func tinyPNG() -> Data {
        let size = CGSize(width: 2, height: 2)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData() ?? Data()
    }

    /// A class, not a struct, so the materializer's callbacks can capture it weakly
    /// without retaining the whole fixture through the run.
    private final class Harness {
        let album: Album
        let manager: CloudKitMigrationManager
        let albumManager: MockAlbumManager
        let store: MockCloudKitMediaStore
        let materializer: FakeICloudDriveMaterializer
        let mediaIDs: [String]

        init(album: Album, manager: CloudKitMigrationManager, albumManager: MockAlbumManager,
             store: MockCloudKitMediaStore, materializer: FakeICloudDriveMaterializer,
             mediaIDs: [String]) {
            self.album = album
            self.manager = manager
            self.albumManager = albumManager
            self.store = store
            self.materializer = materializer
            self.mediaIDs = mediaIDs
        }
    }

    /// Builds an iCloud Drive album with `count` real encrypted photos, then evicts
    /// `evictedCount` of them so they exist only as `.icloud` placeholders — the
    /// state a Drive album is actually in when a user has not opened it in a while.
    private func makeHarness(count: Int, evicting evictedCount: Int? = nil) async throws -> Harness {
        useScratchContainer()
        let album = makeDriveAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let materializer = FakeICloudDriveMaterializer()
        let manager = CloudKitMigrationManager(albumManager: albumManager,
                                               storeFactory: { _ in store },
                                               materializer: materializer)

        let model = iCloudStorageModel(album: album)
        try model.initializeDirectories()
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)

        var ids: [String] = []
        for _ in 0..<count {
            let id = UUID().uuidString
            _ = try await backend.save(
                media: try InteractableMedia(underlyingMedia: [
                    CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: id)
                ]),
                metadata: nil, progress: { _ in })
            ids.append(id)
        }

        for id in ids.prefix(evictedCount ?? count) {
            try materializer.evictForTest(encURL(album: album, id: id))
        }

        return Harness(album: album, manager: manager, albumManager: albumManager,
                       store: store, materializer: materializer, mediaIDs: ids)
    }

    private func encURL(album: Album, id: String) -> URL {
        iCloudStorageModel(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    private func placeholderURL(album: Album, id: String) -> URL {
        ICloudPlaceholderName.placeholderURL(forMaterialized: encURL(album: album, id: id))
    }

    // MARK: - An evicted file is one whose BYTES are gone, not whose path is

    /// The regression test for the bug the rig found and the mocks missed.
    ///
    /// On iOS an evicted ubiquitous file keeps its path — `fileExists` answers
    /// `true` while the bytes live only in iCloud. The engine originally gated on
    /// `fileExists`, so it handed `CKAsset(fileURL:)` a placeholder for all nine
    /// files on the device and every upload failed with `Retry after 3.0s`. The unit
    /// suite stayed green because its fake modelled eviction by DELETING the file, a
    /// state iOS never produces.
    ///
    /// Gate any of these paths on `fileExists` again and this must go red.
    func testFilePresentButNotDownloadedIsNeverUploaded() async throws {
        let h = try await makeHarness(count: 2, evicting: 0)
        // Evict in the shape a real device produces: file still there, bytes not.
        for id in h.mediaIDs {
            try h.materializer.evictForTest(encURL(album: h.album, id: id), shape: .pathPersists)
        }
        for id in h.mediaIDs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: encURL(album: h.album, id: id).path),
                          "precondition: an evicted file keeps its path on iOS")
            XCTAssertFalse(ICloudPlaceholderName.isMaterialized(encURL(album: h.album, id: id)),
                           "precondition: but its bytes are not here")
        }

        // Make every download fail, so nothing can rescue the item: the only
        // question is whether the engine uploads what is on disk anyway.
        h.materializer.urlsThatFailToMaterialize = Set(
            h.mediaIDs.map { encURL(album: h.album, id: $0).lastPathComponent })

        await h.manager.start(album: h.album)

        XCTAssertTrue(h.store.uploadCalls.isEmpty,
                      "a file whose bytes are still in iCloud must NEVER be uploaded — that sends CloudKit a placeholder")
        XCTAssertEqual(h.albumManager.finalizeCallCount, 0,
                       "and the album must not finalize on top of it")
        let loaded = await MigrationPlanStore(album: h.album).load()
        let plan = try XCTUnwrap(loaded)
        XCTAssertTrue(plan.items.allSatisfy { $0.state == .failed },
                      "every such item is a retryable failure, not a skip and not a success")
    }

    func testPlanSizesAnUndownloadedFileFromMetadataNotTheStubOnDisk() async throws {
        // Same trap one level down: statting a file whose path resolves but whose
        // bytes are elsewhere measures the stub. That size then becomes the plan's,
        // and `isPresentInCloudKit` compares the uploaded record against it — so a
        // wrong size here fails verification on every item even once downloads work.
        let h = try await makeHarness(count: 2, evicting: 0)
        let realSizes = h.mediaIDs.reduce(into: [String: Int64]()) { acc, id in
            let url = encURL(album: h.album, id: id)
            acc[url.lastPathComponent] = (try? Data(contentsOf: url).count).map(Int64.init) ?? 0
        }
        for id in h.mediaIDs {
            try h.materializer.evictForTest(encURL(album: h.album, id: id), shape: .pathPersists)
        }

        let plan = try await h.manager.plan(album: h.album)

        XCTAssertEqual(plan.items.count, 2, "both evicted files must be planned — an empty plan would satisfy the sizing check below without checking anything")
        for item in plan.items {
            let name = encURL(album: h.album, id: item.mediaID).lastPathComponent
            XCTAssertEqual(item.sizeBytes, realSizes[name],
                           "the plan must use the file's real size from iCloud's metadata, not the on-disk stub")
        }
    }

    // MARK: - The source is accepted at all

    func testEvictedDriveAlbumIsPlannedWithEveryItem() async throws {
        let h = try await makeHarness(count: 3)

        // Precondition: the bytes are not here. Asserted through the same predicate
        // the engine uses, so it holds for either eviction shape — if this ever
        // stopped being true the rest of the suite would be testing a local album
        // wearing an iCloud Drive label.
        for id in h.mediaIDs {
            XCTAssertFalse(ICloudPlaceholderName.isMaterialized(encURL(album: h.album, id: id)),
                           "an evicted file's bytes must not be on disk")
        }

        let plan = try await h.manager.plan(album: h.album)

        XCTAssertEqual(plan.sourceStorage, .icloud)
        XCTAssertEqual(plan.items.count, 3, "an evicted placeholder is still a file to migrate")
        XCTAssertEqual(Set(plan.items.map(\.mediaID)), Set(h.mediaIDs))
    }

    func testPlanSizesEvictedItemsFromICloudMetadataNotThePlaceholder() async throws {
        let h = try await makeHarness(count: 2)
        let plan = try await h.manager.plan(album: h.album)

        // A placeholder brick is a few hundred bytes. Sizing items from it would
        // make the confirmation alert claim a nonsense total AND break the
        // verification gate, which refuses to delete a source unless the uploaded
        // record's size matches the planned size.
        let sizes = await h.materializer.logicalSizes(
            inAlbumDirectory: iCloudStorageModel(album: h.album).baseURL)
        XCTAssertEqual(plan.items.count, 2, "both evicted files must be planned — an empty plan would satisfy the sizing check below without checking anything")
        for item in plan.items {
            let expected = sizes[encURL(album: h.album, id: item.mediaID).lastPathComponent]
            XCTAssertEqual(item.sizeBytes, expected,
                           "an evicted item must be sized from iCloud's metadata, not the brick")
            XCTAssertGreaterThan(item.sizeBytes, 0)
        }
    }

    func testEstimateReportsRealBytesForAnEvictedDriveAlbum() async throws {
        let h = try await makeHarness(count: 3)
        let estimate = await h.manager.estimate(album: h.album)

        XCTAssertEqual(estimate.itemCount, 3)
        XCTAssertGreaterThan(estimate.totalBytes, 0,
                             "the confirmation alert must not tell the user they are moving 0 bytes")
        XCTAssertFalse(MigrationPlanStore.hasPlan(for: h.album),
                       "estimating must stay side-effect free")
    }

    // MARK: - The happy path

    func testEvictedDriveAlbumMigratesEndToEnd() async throws {
        let h = try await makeHarness(count: 3)
        await h.manager.start(album: h.album)

        XCTAssertEqual(h.manager.state, .completed)
        XCTAssertEqual(h.store.uploadCalls.count, 3, "every evicted file reaches CloudKit exactly once")
        XCTAssertEqual(h.albumManager.finalizeCallCount, 1, "and the album flips to CloudKit")
        XCTAssertFalse(MigrationPlanStore.hasPlan(for: h.album), "the checkpoint is cleared on completion")

        for id in h.mediaIDs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: encURL(album: h.album, id: id).path),
                           "the materialized copy is removed after verification")
            XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(encURL(album: h.album, id: id)),
                           "and nothing is left behind in iCloud Drive in either form")
        }
    }

    func testUploadedBytesMatchTheMaterializedFile() async throws {
        let h = try await makeHarness(count: 2)
        let plannedSizes = try await h.manager.plan(album: h.album)
            .items.reduce(into: [String: Int64]()) { $0[$1.mediaID] = $1.sizeBytes }

        await h.manager.start(album: h.album)

        XCTAssertEqual(h.manager.state, .completed)
        XCTAssertEqual(h.store.uploadedItems.count, 2,
                       "both files must actually reach CloudKit — a run that skipped every item also reports .completed")
        for upload in h.store.uploadedItems {
            XCTAssertEqual(upload.sizeBytes, plannedSizes[upload.mediaID],
                           "the size that reaches CloudKit must be the size verification checks against")
        }
    }

    func testAlreadyMaterializedDriveAlbumMigratesToo() async throws {
        // Not every Drive album is evicted — a recently-used one is fully on disk.
        // It must take the same path without the materializer inventing work.
        let h = try await makeHarness(count: 2, evicting: 0)
        await h.manager.start(album: h.album)

        XCTAssertEqual(h.manager.state, .completed)
        XCTAssertEqual(h.store.uploadCalls.count, 2)
    }

    // MARK: - The data-loss regression

    func testFailedDownloadFailsTheItemRatherThanSkippingIt() async throws {
        let h = try await makeHarness(count: 3)
        let strandedID = h.mediaIDs[1]
        h.materializer.urlsThatFailToMaterialize = [encURL(album: h.album, id: strandedID).lastPathComponent]

        await h.manager.start(album: h.album)

        let loaded = await MigrationPlanStore(album: h.album).load()
        let plan = try XCTUnwrap(loaded, "the checkpoint must survive so the item can be retried")
        let stranded = try XCTUnwrap(plan.items.first { $0.mediaID == strandedID })

        XCTAssertEqual(stranded.state, .failed,
                       "a file that is still only a placeholder has NOT been migrated — marking it .skipped would be terminal and let the album finalize without it")
        XCTAssertNotEqual(stranded.state, .skipped)
        XCTAssertNotNil(stranded.lastError, "and the reason it failed is recorded")
        XCTAssertEqual(h.albumManager.finalizeCallCount, 0,
                       "the album must NOT flip to CloudKit while a file is still in iCloud Drive")
        if case .failed = h.manager.state {} else {
            XCTFail("expected a failed run, got \(h.manager.state)")
        }
        XCTAssertTrue(ICloudPlaceholderName.existsInAnyForm(encURL(album: h.album, id: strandedID)),
                      "and the user's file is still in iCloud Drive, untouched")
    }

    func testResumeAfterAFailedDownloadCompletesTheAlbum() async throws {
        let h = try await makeHarness(count: 3)
        let strandedID = h.mediaIDs[1]
        let strandedName = encURL(album: h.album, id: strandedID).lastPathComponent
        h.materializer.urlsThatFailToMaterialize = [strandedName]

        await h.manager.start(album: h.album)
        XCTAssertEqual(h.albumManager.finalizeCallCount, 0)

        // The network comes back / iCloud catches up.
        h.materializer.urlsThatFailToMaterialize = []
        await h.manager.resume(album: h.album)

        XCTAssertEqual(h.manager.state, .completed)
        XCTAssertEqual(h.albumManager.finalizeCallCount, 1, "the resume finishes the album")
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(encURL(album: h.album, id: strandedID)),
                       "and the file that failed the first time is gone from iCloud Drive too")
        XCTAssertEqual(Set(h.store.uploadCalls), Set(h.mediaIDs),
                       "including the file that failed the first time")
    }

    func testGenuinelyMissingFileIsStillSkipped() async throws {
        // The other side of the same coin: a stale index entry with no file in
        // EITHER form has nothing to migrate and must not wedge the album forever.
        //
        // The file has to disappear AFTER planning. Enumeration reads the
        // filesystem, so deleting it first means it is never planned at all and the
        // skip decision never runs — the account preflight, awaited between planning
        // and the item loop, is the window that puts the ghost in front of it.
        let h = try await makeHarness(count: 2, evicting: 1)
        let survivorID = h.mediaIDs[0]
        let ghostID = h.mediaIDs[1]
        let ghostURL = encURL(album: h.album, id: ghostID)
        let ghostPlaceholder = placeholderURL(album: h.album, id: ghostID)
        h.store.accountAvailableGate = {
            // Truly absent: gone in BOTH forms, so it is not merely evicted.
            try? FileManager.default.removeItem(at: ghostURL)
            try? FileManager.default.removeItem(at: ghostPlaceholder)
        }

        await h.manager.start(album: h.album)

        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(ghostURL),
                       "precondition: this file is genuinely gone, not merely evicted")
        XCTAssertEqual(h.manager.progress.totalCount, 2,
                       "the ghost was in the plan this run executed, so the skip branch is what decided it")
        XCTAssertEqual(h.manager.progress.failedCount, 0,
                       "an absent source is a terminal skip, not a failure that blocks the album forever")
        XCTAssertEqual(h.manager.state, .completed, "a genuinely absent file must not block completion")
        XCTAssertEqual(h.albumManager.finalizeCallCount, 1)
        XCTAssertEqual(h.store.uploadCalls, [survivorID],
                       "and the file that really is there still migrates")
    }

    // MARK: - Batching

    func testMaterializesInBatchesOfTheConfiguredSize() async throws {
        ICloudDriveMigrationBatchSize.current = 2
        let h = try await makeHarness(count: 5)

        await h.manager.start(album: h.album)

        XCTAssertEqual(h.manager.state, .completed)
        XCTAssertEqual(h.materializer.batchSizes, [2, 2, 1],
                       "5 files at a batch size of 2 is three batches, not one download of everything")
        XCTAssertTrue(h.materializer.batchSizes.allSatisfy { $0 <= 2 },
                      "no batch may exceed the configured size — that is the whole point")
    }

    func testBatchSizeIsConfigurable() async throws {
        ICloudDriveMigrationBatchSize.current = 4
        let h = try await makeHarness(count: 5)

        await h.manager.start(album: h.album)

        XCTAssertEqual(h.materializer.batchSizes, [4, 1],
                       "changing the setting must actually change the batching")
    }

    func testDefaultBatchSizeIsUsedWhenUnset() {
        UserDefaultUtils.set(0, forKey: .iCloudDriveMigrationBatchSize)
        XCTAssertEqual(ICloudDriveMigrationBatchSize.current, ICloudDriveMigrationBatchSize.default)

        ICloudDriveMigrationBatchSize.current = 10_000
        XCTAssertEqual(ICloudDriveMigrationBatchSize.current, ICloudDriveMigrationBatchSize.range.upperBound,
                       "an absurd value is clamped rather than trusted")
        ICloudDriveMigrationBatchSize.current = -5
        XCTAssertEqual(ICloudDriveMigrationBatchSize.current, ICloudDriveMigrationBatchSize.range.lowerBound)
    }

    func testLaterBatchesOnlyDownloadAfterEarlierOnesHaveFreedTheirSpace() async throws {
        // The reason batching bounds disk at all: the engine deletes each source
        // once CloudKit has verified it, so batch k+1 downloads into space batch k
        // just freed. If batches overlapped, peak usage would be the whole album
        // and the feature would be pointless.
        ICloudDriveMigrationBatchSize.current = 2
        let h = try await makeHarness(count: 4)

        var materializedAtBatchStart: [Int] = []
        h.materializer.onMaterialize = { [weak h] _ in
            guard let h else { return }
            // `isMaterialized`, not `fileExists`: an evicted file's path still
            // resolves, so counting paths would count every file in the album.
            let onDisk = h.mediaIDs.filter {
                ICloudPlaceholderName.isMaterialized(self.encURL(album: h.album, id: $0))
            }
            materializedAtBatchStart.append(onDisk.count)
        }

        await h.manager.start(album: h.album)

        XCTAssertEqual(h.manager.state, .completed)
        XCTAssertEqual(materializedAtBatchStart, [0, 0],
                       "each batch starts with nothing from the previous batch still on disk")
    }

    // MARK: - Stopping mid-batch

    func testCancelEvictsFilesDownloadedButNotYetUploaded() async throws {
        // Someone cancelling a move because their phone is full must not be left
        // with the downloaded batch still occupying the space that prompted them.
        ICloudDriveMigrationBatchSize.current = 4
        let h = try await makeHarness(count: 4)

        h.materializer.onMaterialize = { [weak h] _ in
            guard let h else { return }
            await h.manager.cancel(album: h.album)
        }

        await h.manager.start(album: h.album)

        XCTAssertFalse(h.materializer.evictedOnStop.isEmpty,
                       "the downloaded-but-unuploaded files are pushed back to iCloud Drive")
        // Again `isMaterialized`, not `fileExists`: after eviction the path is
        // still there, and it is the BYTES that had to go back.
        let stillOnDisk = h.mediaIDs.filter {
            ICloudPlaceholderName.isMaterialized(encURL(album: h.album, id: $0))
        }
        XCTAssertTrue(stillOnDisk.isEmpty, "so no materialized bytes are left behind")
        XCTAssertEqual(h.albumManager.finalizeCallCount, 0)

        let loaded = await MigrationPlanStore(album: h.album).load()
        let plan = try XCTUnwrap(loaded)
        XCTAssertNotNil(plan.cancelledAt, "a cancel stays durable and resumable")
    }

    // MARK: - Progress reporting

    func testRunReportsTheMaterializingPhase() async throws {
        ICloudDriveMigrationBatchSize.current = 2
        let h = try await makeHarness(count: 2)

        var phases: [MigrationPhase] = []
        let cancellable = h.manager.$progress.sink { progress in
            if let phase = progress.phase, phases.last != phase { phases.append(phase) }
        }
        defer { cancellable.cancel() }

        await h.manager.start(album: h.album)

        XCTAssertTrue(phases.contains(.materializing),
                      "downloading from iCloud Drive is real work and must be visible in the overlay")
        XCTAssertTrue(phases.contains(.uploading))
    }

    // MARK: - Local albums are unaffected

    func testLocalAlbumNeverMaterializes() async throws {
        // The shipped local -> CloudKit path must be byte-for-byte what it was:
        // a local album has nothing to download, so the materializer is not touched.
        let keyManager = DemoKeyManager()
        let key = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let album = Album(name: "local-\(UUID().uuidString)", storageOption: .local,
                          creationDate: Date(), key: key)
        keyManager.currentKey = key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let materializer = FakeICloudDriveMaterializer()
        let manager = CloudKitMigrationManager(albumManager: albumManager,
                                               storeFactory: { _ in store },
                                               materializer: materializer)
        defer {
            try? FileManager.default.removeItem(at: LocalStorageModel(album: album).baseURL)
            try? FileManager.default.removeItem(at: MigrationPlanStore.planURL(for: album))
            let marker = CloudKitStorageModel.albumsURL
                .appendingPathComponent(Album.cloudKitTwin(of: album).encryptedPathComponent)
            try? FileManager.default.removeItem(at: marker)
        }

        let model = LocalStorageModel(album: album)
        try model.initializeDirectories()
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        for _ in 0..<2 {
            _ = try await backend.save(
                media: try InteractableMedia(underlyingMedia: [
                    CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: UUID().uuidString)
                ]),
                metadata: nil, progress: { _ in })
        }

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(store.uploadCalls.count, 2,
                       "both local files really migrated — otherwise \"never materialized\" is just \"never did anything\"")
        XCTAssertTrue(materializer.batchSizes.isEmpty,
                      "a local album must never enter the download path")
    }
}
