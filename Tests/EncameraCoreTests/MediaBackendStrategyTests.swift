//
//  MediaBackendStrategyTests.swift
//  EncameraCoreTests
//
//  Chunk 09 — the file-access backend strategy. Proves the facade
//  (`InteractableMediaFileAccess`) picks exactly one `MediaBackend` per album,
//  delegates the I/O surface to it, keeps the index/paging layer uniform across
//  backends, and preserves the cancellation chain after the loops moved out of
//  the facade into the backends.
//

import XCTest
import UIKit
@testable import EncameraCore

// MARK: - Test double

/// A fully in-memory `MediaBackend` so the facade's index/paging layer and the
/// cancellation contract can be tested without a real disk or CloudKit account.
/// Removing the silent `FileEnumerator` defaults means this must implement every
/// member — which is the point.
actor MediaBackendMock: MediaBackend {

    // Instrumentation
    private var reconcileIndexStore: MediaIndexStore?
    private var reconcileEntries: [MediaIndexEntry] = []
    private(set) var reconcileWroteIndex = false

    func setReconcile(store: MediaIndexStore, entries: [MediaIndexEntry]) {
        reconcileIndexStore = store
        reconcileEntries = entries
    }

    // FileEnumerator
    func configure(for album: Album, albumManager: AlbumManaging) async {}
    func enumerateMedia<T>() async -> [InteractableMedia<T>] where T: MediaDescribing { [] }
    func enumerateMediaWithMetadata(
        sortBy: MediaSortOption,
        filterBy: MediaFilterOptions
    ) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] { [] }
    func totalStoredMediaCount() async -> Int { 0 }

    // FileReader
    func loadMediaPreview<T>(for media: InteractableMedia<T>) async throws -> PreviewModel where T: MediaDescribing {
        throw FileAccessError.couldNotLoadMedia
    }
    func loadMedia<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T: MediaDescribing {
        throw FileAccessError.couldNotLoadMedia
    }
    func loadMediaToURLs(media: InteractableMedia<EncryptedMedia>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> [URL] {
        []
    }
    func loadLeadingThumbnail(coverImageId: String?) async throws -> UIImage? { nil }

    // FileWriter
    func save(media: InteractableMedia<CleartextMedia>, metadata: EncryptedFileMetadata?, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? { nil }
    func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        throw FileAccessError.couldNotLoadMedia
    }
    func copy(media: InteractableMedia<EncryptedMedia>) async throws {}
    func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)?) async throws {}
    func delete(media: [InteractableMedia<EncryptedMedia>]) async throws {}
    func deleteAllMedia() async throws {}
    func setKeyUUIDForExistingFiles() async throws {}

    // MediaBackend
    @discardableResult
    func reconcile(onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)?) async -> Bool {
        guard let store = reconcileIndexStore else { return false }
        try? await store.save(MediaIndex(entries: reconcileEntries))
        reconcileWroteIndex = true
        return true
    }
    func sourceURL(id: String, type: MediaType) async -> URL {
        URL(fileURLWithPath: "/mock/\(id).\(type.rawValue)")
    }
    func mediaIndex() async -> MediaIndex? {
        await reconcileIndexStore?.load()
    }
    func storageDetails(for media: InteractableMedia<EncryptedMedia>) async -> MediaStorageDetails? { nil }
    func evictLocalCopy(for media: InteractableMedia<EncryptedMedia>) async throws {}
}

final class MediaBackendStrategyTests: XCTestCase {

    // MARK: - Fixtures

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeAlbum(storage: StorageType) -> Album {
        let key = PrivateKey(name: "test-key", keyBytes: randomKey(), creationDate: Date())
        return Album(name: "\(storage)-\(UUID().uuidString)", storageOption: storage, creationDate: Date(), key: key)
    }

    private func makeManager(for album: Album) -> MockAlbumManager {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        return MockAlbumManager(keyManager: keyManager)
    }

    private func makeEntry(id: String) -> MediaIndexEntry {
        MediaIndexEntry(
            id: id,
            hasPhotoComponent: true,
            hasVideoComponent: false,
            dateEncrypted: Date(timeIntervalSinceReferenceDate: 700_000_000),
            dateTaken: nil,
            subtypeRawValue: MediaFilterOptions.stillImage.rawValue
        )
    }

    private func tempIndexURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaBackendStrategyTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.encindex")
    }

    // MARK: - Backend selection

    func testInteractableMediaFileAccessSelectsDiskBackendForLocalAlbum() async {
        let album = makeAlbum(storage: .local)
        let access = await InteractableMediaFileAccess(for: album, albumManager: makeManager(for: album))
        let backend = await access._testBackend()
        XCTAssertTrue(backend is DiskMediaBackend, "A .local album must select DiskMediaBackend")
        XCTAssertFalse(backend is CloudKitFileAccess, "A .local album must not construct a CloudKitFileAccess")
    }

    func testInteractableMediaFileAccessSelectsCloudBackendForCloudKitAlbum() async {
        let previous = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in MockCloudKitMediaStore() }
        defer { CloudKitStoreProvider.makeStore = previous }

        let album = makeAlbum(storage: .cloudKit)
        let access = await InteractableMediaFileAccess(for: album, albumManager: makeManager(for: album))
        let backend = await access._testBackend()
        XCTAssertTrue(backend is CloudKitFileAccess, "A .cloudKit album must select CloudKitFileAccess")
        XCTAssertFalse(backend is DiskMediaBackend)
    }

    // MARK: - Disk backend behavior parity (grouping)

    func testDiskBackendEnumerationGroupsLivePhotoComponents() async throws {
        let album = makeAlbum(storage: .local)
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer { try? FileManager.default.removeItem(at: model.baseURL) }

        // A Live Photo is a photo + video sharing one media id. Drop both encrypted
        // files directly on disk — enumeration only lists/parses names, no decryption.
        let id = UUID().uuidString
        let photoURL = model.driveURLForMedia(withID: id, type: .photo)
        let videoURL = model.driveURLForMedia(withID: id, type: .video)
        try Data([0, 1, 2, 3]).write(to: photoURL)
        try Data([4, 5, 6, 7]).write(to: videoURL)

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))

        let media: [InteractableMedia<EncryptedMedia>] = await backend.enumerateMedia()
        XCTAssertEqual(media.count, 1, "Photo + video components of one id must collapse to a single InteractableMedia")
        XCTAssertEqual(media.first?.underlyingMedia.count, 2, "Both components must be grouped under the one item")
    }

    // MARK: - Uniform reconcile → reload

    func testReconcileReloadsIndexUniformly() async throws {
        let key = randomKey()
        let indexURL = try tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }
        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)

        let entries = [makeEntry(id: "a"), makeEntry(id: "b")]
        let mock = MediaBackendMock()
        await mock.setReconcile(store: store, entries: entries)

        let access = InteractableMediaFileAccess()
        await access._testSetBackend(mock)

        let changed = await access.reconcileIndex()
        XCTAssertTrue(changed)

        // The facade reads the index straight through the backend after reconcile —
        // the backend owns the index uniformly for disk and cloud.
        let viaFacade = await access.mediaIndex()
        let onDisk = await store.load()
        XCTAssertEqual(viaFacade?.entries.map { $0.id }, onDisk?.entries.map { $0.id })
        XCTAssertEqual(viaFacade?.entries.count, 2)
    }

    // MARK: - Cancellation (the §0 contract)

    func testCancellationStopsBackendEnumeration() async throws {
        // Exercise the REAL backend's per-item loop, not a test double: the §0
        // contract lives in `DiskMediaBackend.loadMediaToURLs`, so that is what
        // must bail. A Live Photo (photo + video, one id) makes it a genuine
        // multi-item loop.
        let album = makeAlbum(storage: .local)
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))

        let id = UUID().uuidString
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(URL(fileURLWithPath: "/x/\(id).encphoto")), mediaType: .photo, id: id),
            EncryptedMedia(source: .url(URL(fileURLWithPath: "/x/\(id).encvideo")), mediaType: .video, id: id)
        ])

        let task = Task { () -> [URL] in
            // Deterministic: don't enter the backend until cancellation has
            // landed, so its first per-item check must observe it.
            while !Task.isCancelled { await Task.yield() }
            return try await backend.loadMediaToURLs(media: media, progress: { _ in })
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled multi-item load must throw CancellationError, not run to completion")
        } catch is CancellationError {
            // expected — the backend's loop bailed at its cancellation check.
            // Any other error (e.g. a load attempt on the nonexistent file)
            // means the check was skipped and the loop did real work.
        }
    }

    func testCancelledReconcileDoesNotWriteIndex() async throws {
        let album = makeAlbum(storage: .local)
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer {
            try? FileManager.default.removeItem(at: model.baseURL)
            try? MediaIndexStore.clearAllIndexes()
        }

        // One on-disk file so reconcile detects an added id and would otherwise
        // write the index.
        let id = UUID().uuidString
        try Data([0, 1, 2, 3]).write(to: model.driveURLForMedia(withID: id, type: .photo))

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))

        XCTAssertFalse(MediaIndexStore.hasIndex(for: album), "precondition: no index yet")

        // Deterministic: an unstructured Task starts concurrently, so racing
        // cancel() against its startup is flaky. Hold the body until the
        // cancellation has landed, then run reconcile — its pre-write
        // cancellation check must bail before saving.
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return await backend.reconcile()
        }
        task.cancel()
        let changed = await task.value

        XCTAssertFalse(changed, "A cancelled reconcile must report no change")
        XCTAssertFalse(MediaIndexStore.hasIndex(for: album), "A cancelled reconcile must not write the index")
    }

    // MARK: - Cloud-specific decisions (§6)

    func testSetKeyUUIDForExistingFilesIsNoOpForCloudAlbum() async throws {
        let album = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        let access = await CloudKitFileAccess(album: album, albumManager: makeManager(for: album), store: store)

        // Must not throw and must not touch CloudKit — key-UUID xattrs are a
        // local-disk concern (decision §6.1).
        try await access.setKeyUUIDForExistingFiles()
        XCTAssertEqual(store.uploadCalls, [], "Cloud setKeyUUIDForExistingFiles must be a pure no-op")
    }

    func testCloudLeadingThumbnailUsesCloudPath() async throws {
        let album = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        let access = await CloudKitFileAccess(album: album, albumManager: makeManager(for: album), store: store)

        // The cover must be resolved through the CloudKit eager-thumbnail fetch
        // (decision §6.2), not a local disk read.
        _ = try? await access.loadLeadingThumbnail(coverImageId: UUID().uuidString)
        XCTAssertGreaterThan(store.fetchThumbnailCount, 0, "Cloud cover resolution must fetch the eager thumbnail from CloudKit")
    }

    // MARK: - Conformance

    func testMediaBackendConformance() async {
        let disk: any MediaBackend = DiskMediaBackend()
        let mock: any MediaBackend = MediaBackendMock()
        let facade: any FileAccess = InteractableMediaFileAccess()
        // `any FileAccess` must also satisfy `any MediaBackend` (it refines it).
        let facadeAsBackend: any MediaBackend = facade
        XCTAssertFalse(disk is CloudKitFileAccess)
        XCTAssertTrue(mock is MediaBackendMock)
        XCTAssertTrue(facadeAsBackend is InteractableMediaFileAccess)
    }
}
