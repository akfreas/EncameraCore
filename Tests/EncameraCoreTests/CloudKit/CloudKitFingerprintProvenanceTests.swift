//
//  CloudKitFingerprintProvenanceTests.swift
//  EncameraCoreTests
//
//  Where a CloudKit record's `keyFingerprint` comes from.
//
//  The field is the only thing that says which key opens a record's ciphertext, and
//  readers decrypt by it without re-deriving anything. That is only safe if every
//  writer PROVES the key against the bytes it is about to upload rather than assuming
//  the album's key or the current one — an album can hold a file written under a
//  different key.
//
//  These tests hold the line at the producer. A record may only claim a key that
//  authenticated its ciphertext, and an item whose key cannot be established must not
//  upload at all: a record carrying a guessed fingerprint makes the field
//  untrustworthy for every reader that follows.
//

import XCTest
import UIKit
import CloudKit
@testable import EncameraCore

@MainActor
final class CloudKitFingerprintProvenanceTests: XCTestCase {

    private let keyA = PrivateKey(name: AppConstants.defaultKeyName,
                                  keyBytes: Array(repeating: 0xA1, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 1_000))
    private let keyB = PrivateKey(name: AppConstants.defaultKeyName,
                                  keyBytes: Array(repeating: 0xB2, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 2_000))
    private let foreignKey = PrivateKey(name: AppConstants.defaultKeyName,
                                        keyBytes: Array(repeating: 0xF0, count: 32),
                                        creationDate: Date(timeIntervalSince1970: 3_000))

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CKFingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Fixtures

    private func tinyPNG() -> Data {
        let size = CGSize(width: 2, height: 2)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    /// A real ENC2 ciphertext file encrypted with `key`, so proof is a genuine AEAD
    /// authentication rather than a stub.
    @discardableResult
    private func writeCiphertext(named name: String,
                                 key: PrivateKey,
                                 in directory: URL? = nil) async throws -> URL {
        let url = (directory ?? tempDirectory).appendingPathComponent(name)
        let cleartext = CleartextMedia(source: .data(tinyPNG()),
                                       mediaType: .photo,
                                       id: url.deletingPathExtension().lastPathComponent)
        let handler = SecretFileHandlerV2(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        return url
    }

    private func keyManager(keys: [PrivateKey], current: PrivateKey) -> DemoKeyManager {
        let manager = DemoKeyManager(keys: keys)
        manager.currentKey = current
        return manager
    }

    // MARK: - The choke point

    /// The headline. The fingerprint must describe the bytes, not the context they are
    /// being uploaded from.
    func testProvenKeyIsTheKeyThatEncryptedTheFileNotTheCurrentKey() async throws {
        let url = try await writeCiphertext(named: "under-a.encrypted", key: keyA)
        let manager = keyManager(keys: [keyA, keyB], current: keyB)

        let proven = try await CloudKitKeyStamp.proveKey(forCiphertextAt: url, keyManager: manager)

        XCTAssertEqual(proven.fingerprint, keyA.keychainLabel,
                       "The file was encrypted with A. Reporting \(proven.fingerprint == keyB.keychainLabel ? "B, the current key" : "another key") "
                       + "would publish a record naming a key that cannot open it.")
    }

    /// An unstamped file — every file written before stamping shipped, and every one
    /// that arrived over iCloud Drive — still has to resolve, by sweeping the library.
    func testUnstampedFileResolvesByProof() async throws {
        let url = try await writeCiphertext(named: "unstamped.encrypted", key: keyA)
        KeyStampSlot.writeStamp(0, url: url)
        XCTAssertNil(KeyStampSlot.readStamp(url: url), "precondition: the fixture carries no stamp")

        let manager = keyManager(keys: [keyB, keyA], current: keyB)
        let proven = try await CloudKitKeyStamp.proveKey(forCiphertextAt: url, keyManager: manager)

        XCTAssertEqual(proven.fingerprint, keyA.keychainLabel,
                       "With no stamp to route by, the sweep must still find the key that authenticates")
    }

    /// The stamp is a 4-byte prefix sitting outside the AEAD, so it can be stale or
    /// rewritten. It orders the candidates; it never decides the answer.
    func testWrongStampDoesNotDecideTheKey() async throws {
        let url = try await writeCiphertext(named: "misstamped.encrypted", key: keyA)
        KeyStampSlot.writeStamp(keyB.stampPrefix, url: url)
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), keyB.stampPrefix,
                       "precondition: the fixture's stamp lies about its key")

        let manager = keyManager(keys: [keyA, keyB], current: keyB)
        let proven = try await CloudKitKeyStamp.proveKey(forCiphertextAt: url, keyManager: manager)

        XCTAssertEqual(proven.fingerprint, keyA.keychainLabel,
                       "The stamp named B and B fails to authenticate, so A must win on proof")
    }

    /// No key, no upload. This is the whole contract: the alternative is a record that
    /// claims a key nobody can check, which is worse than no record at all.
    func testMissingKeyIsAHardFailure() async throws {
        let url = try await writeCiphertext(named: "foreign.encrypted", key: foreignKey)
        let manager = keyManager(keys: [keyA, keyB], current: keyB)

        do {
            let proven = try await CloudKitKeyStamp.proveKey(forCiphertextAt: url, keyManager: manager)
            XCTFail("Expected a failure; got a fingerprint of \(proven.fingerprint)")
        } catch let failure as CloudKitKeyStamp.Failure {
            guard case .missingKey(let fileName, _) = failure else {
                return XCTFail("Expected .missingKey, got \(failure)")
            }
            XCTAssertEqual(fileName, url.lastPathComponent, "the failure has to name the file it is about")
        }
    }

    /// Bytes that are not encrypted media at all are a different failure, and must not
    /// be reported as a missing key — that sends the user hunting for a key phrase to
    /// fix a damaged file.
    func testUnreadableBytesAreNotReportedAsAMissingKey() async throws {
        let url = tempDirectory.appendingPathComponent("garbage.encrypted")
        try Data(repeating: 0x00, count: 32).write(to: url)
        let manager = keyManager(keys: [keyA, keyB], current: keyB)

        do {
            _ = try await CloudKitKeyStamp.proveKey(forCiphertextAt: url, keyManager: manager)
            XCTFail("Expected a failure for unreadable bytes")
        } catch let failure as CloudKitKeyStamp.Failure {
            guard case .unreadable = failure else {
                return XCTFail("Expected .unreadable, got \(failure)")
            }
        }
    }

    /// Closing the loop: the bytes that go up carry their own key hint, so a blob that
    /// comes back down to local storage is self-describing without its record.
    func testProvingStampsTheFileSoTheBlobCarriesItsKey() async throws {
        let url = try await writeCiphertext(named: "to-upload.encrypted", key: keyA)
        KeyStampSlot.writeStamp(0, url: url)
        let manager = keyManager(keys: [keyA, keyB], current: keyB)

        let proven = try await CloudKitKeyStamp.stampAndProveKey(forCiphertextAt: url, keyManager: manager)

        XCTAssertEqual(proven.fingerprint, keyA.keychainLabel)
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), keyA.stampPrefix,
                       "The uploaded ciphertext must carry A's stamp, or a CloudKit -> local move "
                       + "produces a file with nothing on it that names its key")
    }

    /// Stamping must not damage what it stamps: the file still decrypts afterwards.
    func testStampingLeavesTheCiphertextDecryptable() async throws {
        let url = try await writeCiphertext(named: "still-good.encrypted", key: keyA)
        let manager = keyManager(keys: [keyA], current: keyA)

        _ = try await CloudKitKeyStamp.stampAndProveKey(forCiphertextAt: url, keyManager: manager)

        let media = EncryptedMedia(source: url, mediaType: .photo, id: "still-good")
        let handler = SecretFileHandler(keyBytes: keyA.keyBytes, source: media)
        let decrypted = try await handler.decryptInMemory()
        guard case .data(let bytes) = decrypted.source else {
            return XCTFail("expected in-memory bytes back")
        }
        XCTAssertFalse(bytes.isEmpty, "a stamped file must still decrypt to its original content")
    }

    // MARK: - The migration producer

    private func makeMigration(for album: Album,
                               keys: [PrivateKey]) -> (CloudKitMigrationManager, MockAlbumManager, MockCloudKitMediaStore) {
        let keyManager = DemoKeyManager(keys: keys)
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let store = MockCloudKitMediaStore()
        let manager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store })
        return (manager, albumManager, store)
    }

    private func makePhoto(id: String) throws -> InteractableMedia<CleartextMedia> {
        try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: id)
        ])
    }

    /// Lays down real encrypted photos in a local album, encrypted with the album's key.
    private func seedLocalAlbum(count: Int,
                                albumManager: MockAlbumManager,
                                album: Album) async throws -> [String] {
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

    private func sourceEncURL(album: Album, id: String) -> URL {
        album.storageOption.modelForType.init(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    private func cleanUpAlbum(_ album: Album) {
        let model = album.storageOption.modelForType.init(album: album)
        try? FileManager.default.removeItem(at: model.baseURL)
        try? FileManager.default.removeItem(at: MigrationPlanStore.planURL(for: album))
        let marker = CloudKitStorageModel.albumsURL
            .appendingPathComponent(Album.cloudKitTwin(of: album).encryptedPathComponent)
        try? FileManager.default.removeItem(at: marker)
        try? MediaIndexStore.clearAllIndexes()
    }

    private func migratableAlbum(key: PrivateKey) -> Album {
        Album(name: "ckfp-\(UUID().uuidString.prefix(8))",
              storageOption: .local,
              creationDate: Date(),
              key: key)
    }

    /// The headline. An album can hold a file encrypted with a key that is not the
    /// album's, so the album's key is an assumption about every item and the record
    /// must name the key that opened the file itself.
    func testMigrationRecordsTheKeyThatEncryptedEachFileNotTheAlbumKey() async throws {
        let album = migratableAlbum(key: keyA)
        let (manager, albumManager, store) = makeMigration(for: album, keys: [keyA, keyB])
        store.reflectUploadsInMetadata = true
        defer { cleanUpAlbum(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        // One file in the album is under B while the album itself is under A.
        let divergentID = try XCTUnwrap(ids.first)
        try await writeCiphertext(named: sourceEncURL(album: album, id: divergentID).lastPathComponent,
                                  key: keyB,
                                  in: sourceEncURL(album: album, id: divergentID).deletingLastPathComponent())

        await manager.start(album: album)

        let uploads = Dictionary(uniqueKeysWithValues: store.uploadedItems.map { ($0.mediaID, $0) })
        XCTAssertEqual(uploads.count, ids.count, "every item should have been offered for upload")

        let divergent = try XCTUnwrap(uploads[divergentID])
        XCTAssertEqual(divergent.keyFingerprint, keyB.keychainLabel,
                       "This file is encrypted with B. Recording \(divergent.keyFingerprint == keyA.keychainLabel ? "A, the album's key" : "another key") "
                       + "publishes a record naming a key that cannot decrypt its own blob.")

        for id in ids where id != divergentID {
            let upload = try XCTUnwrap(uploads[id])
            XCTAssertEqual(upload.keyFingerprint, keyA.keychainLabel,
                           "the untouched files really are under the album's key and must say so")
        }
    }

    /// A file whose key is not on this device must not reach CloudKit at all. Uploading
    /// it with a guessed fingerprint is what would make the field untrustworthy.
    func testMigrationRefusesToUploadAFileWhoseKeyIsMissing() async throws {
        let album = migratableAlbum(key: keyA)
        let (manager, albumManager, store) = makeMigration(for: album, keys: [keyA])
        store.reflectUploadsInMetadata = true
        defer { cleanUpAlbum(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let strandedID = try XCTUnwrap(ids.first)
        let strandedURL = sourceEncURL(album: album, id: strandedID)
        try await writeCiphertext(named: strandedURL.lastPathComponent,
                                  key: foreignKey,
                                  in: strandedURL.deletingLastPathComponent())

        await manager.start(album: album)

        XCTAssertFalse(store.uploadCalls.contains(strandedID),
                       "the file's key is not in the library, so nothing about it may be published")
        XCTAssertTrue(FileManager.default.fileExists(atPath: strandedURL.path),
                      "and its local original must survive — it is the only copy left")

        let loadedPlan = await MigrationPlanStore(album: album).load()
        let plan = try XCTUnwrap(loadedPlan)
        let stranded = try XCTUnwrap(plan.items.first { $0.mediaID == strandedID })
        XCTAssertEqual(stranded.state, .failed, "the item fails rather than silently skipping")
        XCTAssertNotNil(stranded.lastError, "and it records why, so the user can act on it")
    }

    /// Every record that reaches the store names a key. There is no shipped CloudKit
    /// build, so there is no such thing as a legitimately unlabelled record.
    func testEveryUploadedRecordCarriesAFingerprint() async throws {
        let album = migratableAlbum(key: keyA)
        let (manager, albumManager, store) = makeMigration(for: album, keys: [keyA])
        store.reflectUploadsInMetadata = true
        defer { cleanUpAlbum(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertFalse(store.uploadedItems.isEmpty, "precondition: something uploaded")
        for upload in store.uploadedItems {
            XCTAssertFalse(upload.keyFingerprint.isEmpty,
                           "record \(upload.recordName) went up without naming its key")
        }
        for album in store.savedAlbumCalls {
            XCTAssertFalse(album.keyFingerprint.isEmpty,
                           "album record \(album.albumID) went up without naming its key")
        }
    }

    /// The bytes CloudKit receives carry the stamp, so a blob that later comes back down
    /// to local storage names its own key without needing its record.
    func testUploadedBlobBytesCarryTheKeyStamp() async throws {
        let album = migratableAlbum(key: keyA)
        let (manager, albumManager, store) = makeMigration(for: album, keys: [keyA])
        store.reflectUploadsInMetadata = true
        defer { cleanUpAlbum(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        KeyStampSlot.writeStamp(0, url: sourceEncURL(album: album, id: try XCTUnwrap(ids.first)))
        await manager.start(album: album)

        let recordName = try XCTUnwrap(store.uploadedItems.first?.recordName)
        let blob = try XCTUnwrap(store.uploadedBlobBytes[recordName])
        let stampURL = tempDirectory.appendingPathComponent("uploaded-blob.encrypted")
        try blob.write(to: stampURL)

        XCTAssertEqual(KeyStampSlot.readStamp(url: stampURL), keyA.stampPrefix,
                       "an unstamped blob in CloudKit exports back to a local file with nothing "
                       + "on it that names its key")
    }

    // MARK: - The loop, closed

    /// The proof that matters: read the stamp out of the bytes that came BACK from
    /// CloudKit, not out of the local file we wrote. Only the returned bytes show that
    /// the stamp was written early enough to be part of what was uploaded.
    func testBytesRetrievedFromCloudKitCarryTheKeyStamp() async throws {
        let album = migratableAlbum(key: keyA)
        let (manager, albumManager, store) = makeMigration(for: album, keys: [keyA])
        store.reflectUploadsInMetadata = true
        defer { cleanUpAlbum(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        // Strip the stamp the local write path left, so the only thing that can put one
        // back is the upload path itself. Without this the assertion below is satisfied
        // by stamping that happened long before CloudKit was involved, and proves nothing
        // about the loop — which is the state every iCloud Drive source really arrives in.
        let seededURL = sourceEncURL(album: album, id: try XCTUnwrap(ids.first))
        KeyStampSlot.writeStamp(0, url: seededURL)
        XCTAssertNil(KeyStampSlot.readStamp(url: seededURL), "precondition: nothing has stamped this file")

        await manager.start(album: album)

        let uploaded = try XCTUnwrap(store.uploadedItems.first)
        let downloaded = tempDirectory.appendingPathComponent("round-tripped.encrypted")
        try await store.fetchBlob(recordName: uploaded.recordName, to: downloaded, progress: { _ in })

        XCTAssertEqual(KeyStampSlot.readStamp(url: downloaded), keyA.stampPrefix,
                       "The bytes CloudKit handed back carry no stamp, so a device receiving this "
                       + "blob has nothing on it naming its key — the loop is not closed.")
        XCTAssertEqual(uploaded.keyFingerprint, keyA.keychainLabel)
        XCTAssertEqual(CloudKitKeyStamp.stampPrefix(fromFingerprintHex: uploaded.keyFingerprint),
                       KeyStampSlot.readStamp(url: downloaded),
                       "the record's fingerprint and the blob's own stamp must name the same key")
    }

    // MARK: - The field has to survive the fetch

    /// The trap that comes with making the field required on the read side: a fetch
    /// whose `desiredKeys` omits it hands back records the mapper cannot build, and the
    /// media silently disappears from the album — a worse failure than the one this
    /// branch is fixing. Every list that names fields must name this one.
    func testEveryDesiredKeysListRequestsTheKeyFingerprint() throws {
        XCTAssertTrue(CloudKitMediaStore.metadataKeys.contains(CloudKitSchema.EncMedia.keyFingerprint),
                      "the per-album metadata fetch drops the fingerprint, so every record it "
                      + "returns claims no key")
        XCTAssertTrue(CloudKitMediaStore.changeFeedKeys.contains(CloudKitSchema.EncMedia.keyFingerprint),
                      "the zone change feed drops the media fingerprint")
        XCTAssertTrue(CloudKitMediaStore.changeFeedKeys.contains(CloudKitSchema.EncAlbum.keyFingerprint),
                      "the zone change feed drops the ALBUM fingerprint, so a delta-synced album "
                      + "arrives without the key it needs while the same album from a full fetch has it")
    }

    // MARK: - Album records

    /// An album record's fingerprint has to name the key that decrypts the album's own
    /// name, which is what a receiving device matches on. The album key is proven by
    /// that decryption, so this asserts the provenance rather than assuming it.
    func testAlbumRecordNamesTheKeyThatDecryptsItsName() async throws {
        // The album is under A while the user's current key is B.
        let album = migratableAlbum(key: keyA)
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let store = MockCloudKitMediaStore()
        let manager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store })
        store.reflectUploadsInMetadata = true
        defer { cleanUpAlbum(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        let saved = try XCTUnwrap(store.savedAlbumCalls.first)
        XCTAssertEqual(saved.keyFingerprint, keyA.keychainLabel,
                       "the album's name is encrypted with A, so the record must name A")
        XCTAssertEqual(Album.decryptedAlbumName(saved.encName, key: keyA), album.name,
                       "and that fingerprint must be the key that actually opens the name")
    }

    /// The record names its key, so a device holding several tries that one first. It is
    /// an ordering hint only — the keyed-hash check still decides.
    func testReconcilerTriesTheKeyTheRecordNames() throws {
        let album = Album(name: "hinted-\(UUID().uuidString.prefix(6))",
                          storageOption: .cloudKit,
                          creationDate: Date(),
                          key: keyB)
        let albumID = try XCTUnwrap(SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: keyB.keyBytes))
        let record = CloudKitAlbumMetadata(albumID: albumID,
                                           encName: album.encryptedPathComponent,
                                           createdAt: Date(),
                                           isHidden: false,
                                           schemaVersion: CloudKitSchema.currentSchemaVersion,
                                           keyFingerprint: keyB.keychainLabel,
                                           recordChangeTag: nil)

        let matched = CloudKitAlbumReconciler.match(record: record, keys: [keyA, keyB])
        XCTAssertEqual(matched?.key.keychainLabel, keyB.keychainLabel)
        XCTAssertEqual(matched?.name, album.name)

        // A record whose fingerprint names a key this device does not hold must still be
        // matched by the sweep rather than declared unopenable on the field alone.
        let staleHint = CloudKitAlbumMetadata(albumID: albumID,
                                              encName: album.encryptedPathComponent,
                                              createdAt: Date(),
                                              isHidden: false,
                                              schemaVersion: CloudKitSchema.currentSchemaVersion,
                                              keyFingerprint: foreignKey.keychainLabel,
                                              recordChangeTag: nil)
        XCTAssertEqual(CloudKitAlbumReconciler.match(record: staleHint, keys: [keyA, keyB])?.key.keychainLabel,
                       keyB.keychainLabel,
                       "a wrong fingerprint must cost an ordering miss, not the album")
    }
}
