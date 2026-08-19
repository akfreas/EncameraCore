//
//  CloudKitFileAccessTests.swift
//  EncameraCoreTests
//
//  Chunk 04 — the CloudKit FileAccess branch, exercised against a mock store
//  behind a real coordinator. Encryption is the existing V2 path; only transport
//  is CloudKit. No network, no iCloud account.
//

import XCTest
import CloudKit
import UIKit
@testable import EncameraCore

final class CloudKitFileAccessTests: XCTestCase {

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [FileLoadingStatus] = []
        var values: [FileLoadingStatus] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ s: FileLoadingStatus) { lock.lock(); storage.append(s); lock.unlock() }
    }

    private static func tinyPNG() -> Data {
        let size = CGSize(width: 2, height: 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    private func makeAlbum(name: String = "Vacation-\(UUID().uuidString)", storage: StorageType = .cloudKit) -> Album {
        let key = PrivateKey(name: "test-key", keyBytes: Array(repeating: UInt8(9), count: 32), creationDate: Date())
        return Album(name: name, storageOption: storage, creationDate: Date(), key: key)
    }

    private func makeAccess(album: Album, store: MockCloudKitMediaStore) async -> CloudKitFileAccess {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        return await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)
    }

    private func photo(id: String = UUID().uuidString, data: Data) throws -> InteractableMedia<CleartextMedia> {
        let media = CleartextMedia(source: .data(data), mediaType: .photo, id: id)
        return try InteractableMedia(underlyingMedia: [media])
    }

    private func encURL(for album: Album, id: String) -> URL {
        CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    /// Produce a valid ENC2 ciphertext for `data` so a load can be tested as a
    /// pure cloud fetch (no prior local save that would warm the coordinator cache).
    private func makeENC2(album: Album, id: String, data: Data, mediaType: MediaType = .photo) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).enc")
        let cleartext = CleartextMedia(source: .data(data), mediaType: mediaType, id: id)
        let handler = SecretFileHandlerV2(keyBytes: album.key.keyBytes, source: cleartext, targetURL: tmp)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bytes = try Data(contentsOf: tmp)
        XCTAssertEqual(Array(bytes.prefix(4)), EncryptedFileFormat.magic, "Fixture must be a genuine V2 file")
        return bytes
    }

    /// Produce a **genuine V1** ciphertext with the exact call the app's own no-metadata save
    /// makes: `DiskFileAccess.save(metadata: nil)` takes the `SecretFileHandler.encrypt()`
    /// branch, which writes the older format with no ENC2 magic. (Going through
    /// `DiskFileAccess.save` itself would also drag in `createPreview`, which needs decodable
    /// image bytes; `testDiskSaveWithoutMetadataProducesV1Ciphertext` pins that the app path
    /// really does produce this format.) This is what a legacy local library is full of, and
    /// migration uploads those bytes to CloudKit verbatim — no re-encryption (ENC-135).
    private func makeV1(key: PrivateKey, id: String, data: Data, mediaType: MediaType = .photo) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).enc")
        let cleartext = CleartextMedia(source: .data(data), mediaType: mediaType, id: id)
        let handler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartext, targetURL: tmp)
        _ = try await handler.encrypt()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bytes = try Data(contentsOf: tmp)
        XCTAssertNotEqual(Array(bytes.prefix(4)), EncryptedFileFormat.magic,
                          "Fixture must be a genuine V1 file — V1 carries no ENC2 magic")
        return bytes
    }

    // MARK: - Save

    func testSaveEncryptsThenUploads() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("super secret cleartext".utf8)
        _ = try await access.save(media: photo(id: id, data: cleartext), metadata: nil, progress: { _ in })
        // Saves are local-first: the upload happens in the background. Drain it
        // so the store has been given the record before asserting.
        await access.drainUploads()

        XCTAssertEqual(store.uploadCalls, [id])
        let upload = try XCTUnwrap(store.uploadedItems.first)

        // Uploaded bytes are ciphertext: the file CloudKit read is an ENC2 file.
        // (Asserted on the bytes captured at upload time — the holding-folder
        // copy is deleted once the upload completes.)
        let bytes = try XCTUnwrap(store.uploadedBlobBytes[upload.recordName])
        XCTAssertEqual(Array(bytes.prefix(4)), EncryptedFileFormat.magic, "Uploaded file must be ENC2 ciphertext")
        XCTAssertFalse(bytes.contains(Data("super secret cleartext".utf8)), "No plaintext may appear in the uploaded file")

        // albumID is the keyed hash, not the cleartext album name.
        XCTAssertNotEqual(upload.albumID, album.name)
        XCTAssertEqual(upload.albumID, SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes))

        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    /// Every ordinary capture/import — not just the one-time migration path — must
    /// stamp the record with the key that encrypted it, so the census can name the
    /// key a library needs. Guards the `keyFingerprint:` argument at the
    /// `CloudKitMediaUpload` construction site in `saveSingle`.
    func testSavedMediaIsStampedWithTheAlbumKeyFingerprint() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        _ = try await access.save(media: photo(id: id, data: Data("cleartext".utf8)), metadata: nil, progress: { _ in })
        await access.drainUploads()

        let upload = try XCTUnwrap(store.uploadedItems.first)
        XCTAssertEqual(upload.keyFingerprint, album.key.keychainLabel,
                       "every saved record must name the key that encrypted it")
        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 1, fingerprints: [album.key.keychainLabel: 1]),
                       "so the census can name the key for an ordinary capture")

        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    // MARK: - Load

    func testLoadFetchesLazilyThenDecrypts() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("decrypt round trip".utf8)
        // The blob exists only in the cloud (never saved locally) -> first load fetches.
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        store.blobContents = try await makeENC2(album: album, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])

        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)
        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)

        // Second load is served from the now-local copy — no duplicate fetch.
        _ = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1, "Second load must not re-fetch")

        try? FileManager.default.removeItem(at: localURL)
    }

    func testProgressMapsDownloadThenDecrypt() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        store.blobContents = try await makeENC2(album: album, id: id, data: Data("progress".utf8))

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])

        let box = StatusBox()
        _ = try await access.loadMedia(media: encrypted, progress: { box.append($0) })

        let kinds = box.values.map { status -> String in
            switch status {
            case .downloading: return "downloading"
            case .decrypting: return "decrypting"
            case .loaded: return "loaded"
            case .notLoaded: return "notLoaded"
            }
        }
        XCTAssertTrue(kinds.contains("downloading"))
        XCTAssertTrue(kinds.contains("decrypting"))
        XCTAssertEqual(kinds.last, "loaded")
        // Ordering: a download status precedes a decrypt status.
        if let d = kinds.firstIndex(of: "downloading"), let c = kinds.firstIndex(of: "decrypting") {
            XCTAssertLessThan(d, c)
        } else {
            XCTFail("Expected both downloading and decrypting statuses")
        }
        try? FileManager.default.removeItem(at: localURL)
    }

    // MARK: - Enumeration

    func testEnumerateReadsFromSyncedIndexNotNetwork() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.fetchBlobError = CKErrorFactory.error(.networkUnavailable)  // any direct fetch would fail
        let albumIDHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        store.changeSet = CloudKitChangeSet(
            changed: [
                CloudKitMediaMetadata(recordName: "m1", albumID: albumIDHash, mediaID: "m1", mediaType: .photo,
                                      createdAt: Date(timeIntervalSince1970: 200), sizeBytes: 1, creationDeviceID: "d",
                                      deletedAt: nil, schemaVersion: 1, recordChangeTag: "t1"),
                CloudKitMediaMetadata(recordName: "m2", albumID: albumIDHash, mediaID: "m2", mediaType: .photo,
                                      createdAt: Date(timeIntervalSince1970: 100), sizeBytes: 1, creationDeviceID: "d",
                                      deletedAt: nil, schemaVersion: 1, recordChangeTag: "t2")
            ],
            deleted: [], token: nil, moreComing: false
        )
        let access = await makeAccess(album: album, store: store)

        _ = await access.reconcile()
        let media = await access.enumerate()

        XCTAssertEqual(Set(media.map { $0.id }), ["m1", "m2"])
        XCTAssertEqual(store.fetchBlobCount, 0, "Enumeration must not hit the network")
    }

    // MARK: - Delete

    func testDeleteRoutesToCoordinatorRemove() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: "m1")), mediaType: .photo, id: "m1")
        ])
        try await access.delete(media: [encrypted])

        // The delete addresses the component record — "m1#0" for the photo
        // component — and removes it outright; the zone change feed is what
        // carries that to other devices.
        XCTAssertEqual(store.deleteCalls, [CloudKitFileAccess.componentRecordName(mediaID: "m1", type: .photo)])
    }

    /// Deleting a photo that has NOT uploaded yet (offline, or before the drain
    /// ran) must remove it from the album. Regression: the remote call throws
    /// `.notFound` for a record the zone has never seen, and that error used to
    /// abort `remove` before any local cleanup ran — the queue entry and
    /// ciphertext were already gone, but the index entry survived as a permanent,
    /// unopenable ghost the user could never delete.
    func testDeletingAPendingItemRemovesItFromTheAlbum() async throws {
        let album = makeAlbum()
        // A long upload delay pins the capture in the pending state: the
        // background drain cannot complete before the delete runs.
        let store = InMemoryCloudKitMediaStore(uploadDelay: .seconds(30))
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)

        let id = UUID().uuidString
        let saved = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
        ]), metadata: nil, progress: { _ in })

        let visible = await access.enumerate()
        XCTAssertEqual(visible.count, 1, "A pending capture must be visible before it uploads")

        try await access.delete(media: [try XCTUnwrap(saved)])

        let after = await access.enumerate()
        XCTAssertEqual(after.count, 0, "Deleting a pending item must remove it from the album, not leave a ghost")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    // MARK: - Availability / regression guards

    func testCloudKitUnavailableWhenFlagOff() {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }

        let availability = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .cloudKit)
        guard case .unavailable = availability else {
            return XCTFail("cloudKit must be unavailable when the flag is off")
        }
    }

    func testLocalAndICloudModelsUnchanged() {
        // Regression guard for hard requirement #1: the existing storage planes are untouched.
        XCTAssertTrue(StorageType.local.modelForType == LocalStorageModel.self)
        XCTAssertTrue(StorageType.icloud.modelForType == iCloudStorageModel.self)
        XCTAssertTrue(StorageType.cloudKit.modelForType == CloudKitStorageModel.self)
        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .local), .available)
    }

    // MARK: - Bugbot regressions

    func testLivePhotoUploadsTwoDistinctRecords() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let photoPart = CleartextMedia(source: .data(Data("photo".utf8)), mediaType: .photo, id: id)
        let videoPart = CleartextMedia(source: .data(Data("video".utf8)), mediaType: .video, id: id)
        let live = try InteractableMedia(underlyingMedia: [photoPart, videoPart])
        XCTAssertEqual(live.mediaType, .livePhoto)

        _ = try await access.save(media: live, metadata: nil, progress: { _ in })
        await access.drainUploads()

        XCTAssertEqual(store.uploadedItems.count, 2)
        let recordNames = Set(store.uploadedItems.map { $0.recordName })
        XCTAssertEqual(recordNames.count, 2, "Each Live Photo component must be its own CloudKit record")
        XCTAssertEqual(Set(store.uploadedItems.map { $0.mediaID }), [id], "Both components share the grouping id")

        for type in [MediaType.photo, .video] {
            try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: type))
        }
    }

    func testCloudKitAlbumRoutesToCloudEvenWhenFlagOff() async throws {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        let shared = InMemoryCloudKitMediaStore()
        let previousProvider = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer {
            FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled)
            CloudKitStoreProvider.makeStore = previousProvider
        }

        let album = makeAlbum()   // .cloudKit
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await InteractableMediaFileAccess(for: album, albumManager: albumManager)

        let id = UUID().uuidString
        // Real image bytes so DiskFileAccess.createPreview wouldn't throw — the test
        // must fail on routing, not thumbnail generation, before the fix.
        let imageData = Self.tinyPNG()
        let photo = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(imageData), mediaType: .photo, id: id)
        ])
        _ = try await access.save(media: photo, metadata: nil, progress: { _ in })
        // The facade uses the production path (shared registry + shared uploader);
        // drain the shared uploader so the background upload reaches the store.
        await CloudKitUploader.shared.drainNow()

        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        let metadata = try await shared.fetchMetadata(albumID: albumHash, includeThumbnail: false)
        XCTAssertEqual(metadata.count, 1, "A .cloudKit album must use CloudKit even when the flag is off")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .photo))
    }

    func testEnumerateWithMetadataReadsFromIndexNotNetwork() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.fetchBlobError = CKErrorFactory.error(.networkUnavailable)
        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "m1", albumID: albumHash, mediaID: "m1", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 300), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t1"),
            CloudKitMediaMetadata(recordName: "m2", albumID: albumHash, mediaID: "m2", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 200), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t2")
        ], deleted: [], token: nil, moreComing: false)
        let access = await makeAccess(album: album, store: store)

        _ = await access.reconcile()
        let result = await access.enumerateMediaWithMetadata(sortBy: .dateEncrypted(ascending: false), filterBy: .all)

        XCTAssertEqual(Set(result.map { $0.media.id }), ["m1", "m2"])
        XCTAssertEqual(store.fetchBlobCount, 0, "Metadata enumeration must not hit the network")
    }

    func testDeleteAllTombstonesEveryCloudKitRecord() async throws {
        let album = makeAlbum()
        let store = InMemoryCloudKitMediaStore()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)

        for _ in 0..<2 {
            let id = UUID().uuidString
            let photo = try InteractableMedia(underlyingMedia: [
                CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
            ])
            _ = try await access.save(media: photo, metadata: nil, progress: { _ in })
        }
        await access.drainUploads()

        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        let before = try await store.fetchMetadata(albumID: albumHash, includeThumbnail: false)
        XCTAssertEqual(before.count, 2)

        try await access.deleteAllMedia()

        let after = try await store.fetchMetadata(albumID: albumHash, includeThumbnail: false)
        XCTAssertEqual(after.count, 0, "deleteAll must remove every CloudKit record for the album")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
    }

    func testSaveEnsuresZoneBeforeUpload() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        _ = try await access.save(media: try photo(id: id, data: Data("zone".utf8)), metadata: nil, progress: { _ in })

        XCTAssertGreaterThanOrEqual(store.ensureZoneCalls, 1, "Save must ensure the zone exists before uploading")
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    func testLoadRefetchesWhenChangeTagAdvances() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!

        func meta(tag: String) -> CloudKitMediaMetadata {
            CloudKitMediaMetadata(recordName: "m#0", albumID: albumHash, mediaID: "m", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: tag)
        }
        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: "m")), mediaType: .photo, id: "m")
        ])

        // v1 at tag t1
        store.changeSet = CloudKitChangeSet(changed: [meta(tag: "t1")], deleted: [], token: nil, moreComing: false)
        _ = await access.reconcile()
        store.blobContents = try await makeENC2(album: album, id: "m", data: Data("v1".utf8))
        let first = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(first.underlyingMedia.first?.data, Data("v1".utf8))
        XCTAssertEqual(store.fetchBlobCount, 1)

        // A remote re-upload advances the tag to t2 with new content.
        store.changeSet = CloudKitChangeSet(changed: [meta(tag: "t2")], deleted: [], token: nil, moreComing: false)
        _ = await access.reconcile()
        store.blobContents = try await makeENC2(album: album, id: "m", data: Data("v2".utf8))
        let second = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(second.underlyingMedia.first?.data, Data("v2".utf8), "Stale tag must trigger a refetch")
        XCTAssertEqual(store.fetchBlobCount, 2)
    }

    func testSaveRecreatesZoneOnZoneNotFound() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.uploadErrorOnce = CloudKitMediaStoreError.zoneNotFound
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        _ = try await access.save(media: try photo(id: id, data: Data("z".utf8)), metadata: nil, progress: { _ in })
        await access.drainUploads()

        XCTAssertEqual(store.recreateZoneCount, 1, "A zoneNotFound upload must recreate the zone")
        XCTAssertEqual(store.uploadCalls.count, 2, "Upload should retry once after recreating the zone")
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    func testStorageModelFolderMatchesBlobCacheKey() {
        let album = makeAlbum()
        let albumID = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        let expected = CloudKitBlobCache.albumFolderName(albumID)
        let baseURL = CloudKitStorageModel(album: album).baseURL
        XCTAssertEqual(baseURL.lastPathComponent, expected,
                       "Storage model folder must match the blob cache's per-album key")
        XCTAssertEqual(baseURL.deletingLastPathComponent().standardizedFileURL.path,
                       CloudKitBlobCache.defaultBaseDir.standardizedFileURL.path)
        try? FileManager.default.removeItem(at: baseURL)
    }

    func testEntryCountForCloudKitAlbumReadsIndex() async throws {
        let album = makeAlbum()
        let indexStore = MediaIndexStore(album: album)
        let entries = ["a", "b", "c"].map {
            MediaIndexEntry(id: $0, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: Date(), dateTaken: Date(), subtypeRawValue: 0)
        }
        try await indexStore.save(MediaIndex(entries: entries))
        defer { try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album)) }

        XCTAssertEqual(MediaIndexStore.entryCount(for: album), 3,
                       "CloudKit album count must come from the synced index, not on-disk files")
    }

    func testBlobCacheIndexSurvivesRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ckcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).bin")
        try Data("ciphertext".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let cache1 = CloudKitBlobCache(baseDir: dir)
        _ = try await cache1.store(recordName: "rec#0", changeTag: "t1", albumID: "albumHash", from: src)

        // A fresh instance (app relaunch) over the same directory must recover the
        // cached entry instead of re-downloading and leaking the orphan.
        let cache2 = CloudKitBlobCache(baseDir: dir)
        let url = await cache2.cachedURL(recordName: "rec#0", changeTag: "t1")
        XCTAssertNotNil(url, "Cache index should be restored from disk on init")
    }

    func testSaveOmitsThumbnailWhenPreviewMissing() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        // Non-image bytes => preview generation fails => no preview file on disk.
        _ = try await access.save(media: try photo(id: id, data: Data("not an image".utf8)), metadata: nil, progress: { _ in })
        await access.drainUploads()

        let upload = try XCTUnwrap(store.uploadedItems.first)
        XCTAssertNil(upload.encryptedThumbURL, "A missing preview must not be uploaded as a thumbnail asset")
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    func testCloudKitAlbumsSyncReconcilesInactiveAlbums() async throws {
        let shared = InMemoryCloudKitMediaStore()
        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer { CloudKitStoreProvider.makeStore = prev }

        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]

        // Upload a photo so the cloud has a record for this album.
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: shared)
        let id = UUID().uuidString
        _ = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
        ]), metadata: nil, progress: { _ in })
        await access.drainUploads()

        // Simulate a device that hasn't built this album's index yet.
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
        XCTAssertEqual(MediaIndexStore.entryCount(for: album), 0)

        // The fan-out sync must rebuild it without the album being "active".
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false)
        await sync.syncAll()

        XCTAssertEqual(MediaIndexStore.entryCount(for: album), 1, "syncAll must reconcile inactive CloudKit albums")
        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    /// The delete path must NOT be gated on the `cloudKitStorage` flag:
    /// `CloudKitAlbumsSync` keeps reconciling existing `.cloudKit` albums with the
    /// flag off, so a flag-gated delete would queue nothing and the reconciler would
    /// resurrect the album on the very device that deleted it.
    func testDeleteRemovesCloudKitAlbumRecordEvenWhenFlagOff() async throws {
        let shared = InMemoryCloudKitMediaStore()
        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer { CloudKitStoreProvider.makeStore = prev }

        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }

        let album = makeAlbum()
        let hash = try XCTUnwrap(SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes))
        try await shared.saveAlbum(CloudKitAlbumUpload(albumID: hash,
                                                       encName: album.encryptedPathComponent,
                                                       createdAt: album.creationDate,
                                                       isHidden: false))

        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        albumManager.delete(album: album)
        defer {
            CloudKitAlbumDeleteQueue().remove(hash)
            CloudKitAlbumPublishRegistry().forget(hash)
        }

        // The delete is fire-and-forget; wait for it to land in the store.
        for _ in 0..<100 {
            if try await shared.fetchAllAlbums().allSatisfy({ $0.albumID != hash }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let remaining = try await shared.fetchAllAlbums().filter { $0.albumID == hash }
        XCTAssertTrue(remaining.isEmpty,
                      "Deleting a .cloudKit album with the flag off must still remove its EncAlbum record")
    }

    /// A `syncAll` that joins an in-flight run may have missed the fetch/reconcile
    /// already past — the join must flag a re-run so the change it carries is honored
    /// by one extra pass instead of silently dropped until the next trigger.
    func testSyncAllJoinerMidRunTriggersExtraPass() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let released = Flag()
        let store = MockCloudKitMediaStore()
        store.fetchAllAlbumsGate = { while !released.isSet() { await Task.yield() } }

        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]

        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in InMemoryCloudKitMediaStore() }
        defer { CloudKitStoreProvider.makeStore = prev }

        // `UserDefaults` is not `Sendable`, so the `@Sendable` factory below builds
        // its own instance from the suite name.
        let suite = makeIsolatedSuiteName()
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false, makeReconciler: { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    deleteQueue: CloudKitAlbumDeleteQueue(defaults: defaults(forSuite: suite)),
                                    publishRegistry: CloudKitAlbumPublishRegistry(defaults: defaults(forSuite: suite)))
        })

        let first = Task { await sync.syncAll() }
        while store.fetchAllAlbumsCount < 1 { await Task.yield() }   // first pass is mid-run, held by the gate

        let second = Task { await sync.syncAll() }                    // joins the in-flight run
        while !(await sync.resyncRequested) { await Task.yield() }    // the join has been recorded
        released.set()

        await first.value
        await second.value
        XCTAssertEqual(store.fetchAllAlbumsCount, 2,
                       "A syncAll joining mid-run must be honored by exactly one extra pass")
    }

    func testMaterializedSourceUsesCacheRecordPath() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "m#0", albumID: albumHash, mediaID: "m", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t1")
        ], deleted: [], token: nil, moreComing: false)
        let access = await makeAccess(album: album, store: store)
        _ = await access.reconcile()

        let media = await access.enumerate()
        let source = media.first?.underlyingMedia.first?.source
        guard case .url(let url)? = source else { return XCTFail("Expected a url source") }
        // Must point at the cache/record-name path so a lazily downloaded blob resolves.
        XCTAssertEqual(url.lastPathComponent, CloudKitFileAccess.componentRecordName(mediaID: "m", type: .photo))
    }

    func testCloudKitMediaPageUsesCacheRecordPath() async throws {
        let shared = InMemoryCloudKitMediaStore()
        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer { CloudKitStoreProvider.makeStore = prev }

        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await InteractableMediaFileAccess(for: album, albumManager: albumManager)

        let id = UUID().uuidString
        _ = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
        ]), metadata: nil, progress: { _ in })

        let page = await access.mediaPage(sortBy: .dateEncrypted(ascending: false), filterBy: .all, offset: 0, pageSize: 10)
        let source = page.media.first?.underlyingMedia.first?.source
        guard case .url(let url)? = source else { return XCTFail("Expected a url source") }
        XCTAssertEqual(url.lastPathComponent, CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                       "mediaPage must materialize CloudKit media at the cache record path")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    func testFailedThumbnailFetchDoesNotCacheTag() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        // A synced item gives a non-nil current change tag for "p#0".
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "p#0", albumID: albumHash, mediaID: "p", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t1")
        ], deleted: [], token: nil, moreComing: false)
        let access = await makeAccess(album: album, store: store)
        _ = await access.reconcile()

        // The fetch writes a (partial) file then fails — so the file exists but is bad.
        store.fetchThumbnailWritesFile = true
        store.fetchThumbnailError = CloudKitMediaStoreError.notFound

        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: "p")), mediaType: .photo, id: "p")
        ])
        for _ in 0..<2 {
            _ = try? await access.loadMediaPreview(for: media)
        }

        XCTAssertEqual(store.fetchThumbnailCount, 2, "A failed thumbnail fetch must be retried, not recorded as current")
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    func testCloudKitAlbumIsDiscoverable() throws {
        let key = PrivateKey(name: "disc-key", keyBytes: Array(repeating: UInt8(5), count: 32), creationDate: Date())
        let name = "CKDisc-\(UUID().uuidString)"
        let album = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key)

        // Place the discovery marker the way album creation does.
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: marker) }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = key
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        XCTAssertTrue(albums.contains { $0.storageOption == .cloudKit && $0.name == name },
                      "A CloudKit album marker must be discoverable in the album list")
    }

    // MARK: - Mixed on-disk format support (ENC-135)
    //
    // Migration is a move of ciphertext, not a re-encode: whatever format the bytes had
    // on disk is the format that lands in CloudKit. A legacy library holds V1 files, so
    // the CloudKit read path must decrypt V1 as well as V2 — the reader adapts to the
    // data, the data is never rewritten to suit the reader.

    /// Why V1 blobs exist at all: the app's own local save writes V1 whenever no metadata is
    /// supplied. Anchors the `makeV1` fixture to the real production path.
    func testDiskSaveWithoutMetadataProducesV1Ciphertext() async throws {
        let key = PrivateKey(name: "v1-disk-key", keyBytes: Array(repeating: UInt8(3), count: 32), creationDate: Date())
        let album = Album(name: "V1Source-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let albumManager = DemoAlbumManager()
        albumManager.keyManager = keyManager
        let disk = DiskFileAccess()
        await disk.configure(for: album, albumManager: albumManager)

        // Real image bytes so the preview pipeline inside save() succeeds — the point of the
        // test is the ciphertext format, not thumbnailing.
        let imageData = Self.tinyPNG()

        let v1 = try await disk.save(media: CleartextMedia(source: .data(imageData), mediaType: .photo, id: UUID().uuidString),
                                     metadata: nil, progress: { _ in })
        let v1URL = try XCTUnwrap(v1?.url)
        defer { try? FileManager.default.removeItem(at: v1URL) }
        XCTAssertNotEqual(Array(try Data(contentsOf: v1URL).prefix(4)), EncryptedFileFormat.magic,
                          "A save without metadata must produce a V1 file — this is why legacy libraries hold V1")

        // The metadata-bearing branch must still produce V2: the fix must not have changed writes.
        let v2 = try await disk.save(media: CleartextMedia(source: .data(imageData), mediaType: .photo, id: UUID().uuidString),
                                     metadata: EncryptedFileMetadata(), progress: { _ in })
        let v2URL = try XCTUnwrap(v2?.url)
        defer { try? FileManager.default.removeItem(at: v2URL) }
        XCTAssertEqual(Array(try Data(contentsOf: v2URL).prefix(4)), EncryptedFileFormat.magic,
                       "A save with metadata must still produce V2")
    }

    /// The regression itself: a V1 blob through `loadMedia`'s photo branch (`decryptInMemory`).
    /// Before the fix this threw "V1 file detected" and the item was unreadable on every device.
    func testLoadDecryptsV1CiphertextInMemory() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("legacy v1 photo cleartext".utf8)
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        // Exactly the bytes migration would have uploaded, untouched.
        store.blobContents = try await makeV1(key: album.key, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])
        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext,
                       "A V1 blob migrated into a CloudKit album must decrypt to its original cleartext")
    }

    /// The same V1 blob through `loadMedia`'s non-photo branch (`decryptToURL`).
    func testLoadDecryptsV1CiphertextToURL() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data((0..<40000).map { UInt8($0 % 251) })   // spans several blocks
        let localURL = CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .video)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeV1(key: album.key, id: id, data: cleartext, mediaType: .video)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .video, id: id)
        ])
        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })

        let outURL = try XCTUnwrap(decrypted.underlyingMedia.first?.url)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    /// `loadMediaToURLs` is a separate decrypt site and needed the same fix.
    func testLoadMediaToURLsDecryptsV1Ciphertext() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("legacy v1 export cleartext".utf8)
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeV1(key: album.key, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])
        let urls = try await access.loadMediaToURLs(media: encrypted, progress: { _ in })

        let outURL = try XCTUnwrap(urls.first)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    /// V2 must keep working through every site the fix touched — the format-agnostic
    /// handler is a superset, not a swap.
    func testLoadDecryptsV2CiphertextToURL() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data((0..<40000).map { UInt8($0 % 241) })
        let localURL = CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .video)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeENC2(album: album, id: id, data: cleartext, mediaType: .video)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .video, id: id)
        ])
        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })

        let outURL = try XCTUnwrap(decrypted.underlyingMedia.first?.url)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    func testLoadMediaToURLsDecryptsV2Ciphertext() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("v2 export cleartext".utf8)
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeENC2(album: album, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])
        let urls = try await access.loadMediaToURLs(media: encrypted, progress: { _ in })

        let outURL = try XCTUnwrap(urls.first)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    /// Pins the corrected doc comment on `SecretFileHandlerV2`: it is V2-only and *throws*
    /// on V1. If someone ever teaches it V1 compatibility this test should be deleted along
    /// with the comment — but until then the comment must not claim otherwise.
    func testSecretFileHandlerV2ThrowsOnV1WhileSecretFileHandlerReadsIt() async throws {
        let key = PrivateKey(name: "v1-key", keyBytes: Array(repeating: UInt8(7), count: 32), creationDate: Date())
        let id = UUID().uuidString
        let cleartext = Data("format sniffing cleartext".utf8)
        let v1Bytes = try await makeV1(key: key, id: id, data: cleartext)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-v1.\(MediaType.photo.encryptedFileExtension)")
        try v1Bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let encMedia = EncryptedMedia(source: .url(url), mediaType: .photo, id: id)

        do {
            _ = try await SecretFileHandlerV2(keyBytes: key.keyBytes, source: encMedia).decryptInMemory()
            XCTFail("SecretFileHandlerV2 is V2-only and must throw on a V1 file")
        } catch let error as SecretFilesError {
            guard case .decryptError = error else {
                return XCTFail("Expected a decryptError, got \(error)")
            }
        }

        let readable = try await SecretFileHandler(keyBytes: key.keyBytes, source: encMedia).decryptInMemory()
        XCTAssertEqual(readable.data, cleartext, "SecretFileHandler must read the same V1 file")
    }

    func testStorageTypeCodableRoundTripsCloudKit() throws {
        let data = try JSONEncoder().encode(StorageType.cloudKit)
        let decoded = try JSONDecoder().decode(StorageType.self, from: data)
        XCTAssertEqual(decoded, .cloudKit)

        let album = makeAlbum()
        let albumData = try JSONEncoder().encode(album)
        let decodedAlbum = try JSONDecoder().decode(Album.self, from: albumData)
        XCTAssertEqual(decodedAlbum.storageOption, .cloudKit)
    }
}
