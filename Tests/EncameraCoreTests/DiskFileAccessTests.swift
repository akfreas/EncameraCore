import XCTest
@testable import EncameraCore

/// Records `keyWith(uuid:)` lookups and `storedKeys()` calls so tests can
/// tell hint-based resolution (xattr, memo) apart from a discovery sweep —
/// `discoverKey` always fetches the stored keys, hint paths never do.
final class SpyKeyManager: DemoKeyManager {
    var keyWithUUIDCalls: [UUID] = []
    var storedKeysCalls = 0

    override func keyWith(uuid: UUID) -> PrivateKey? {
        keyWithUUIDCalls.append(uuid)
        return super.keyWith(uuid: uuid)
    }

    override func storedKeys() throws -> [PrivateKey] {
        storedKeysCalls += 1
        return try super.storedKeys()
    }
}

/// iCloud-shaped storage model backed by a temp directory, so the local-only
/// stamping gate can be tested without a real ubiquity container
/// (`iCloudStorageModel.rootURL` fatalErrors when iCloud is unavailable).
struct FakeICloudStorageModel: DataStorageModel {
    static let rootURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FakeICloudStorageModel", isDirectory: true)

    let album: Album
    var storageType: StorageType { .icloud }
    var baseURL: URL { Self.rootURL.appendingPathComponent(album.encryptedPathComponent, isDirectory: true) }

    init(album: Album) {
        self.album = album
    }
}

final class FakeICloudAlbumManager: DemoAlbumManager {
    override func storageModel(for album: Album) -> DataStorageModel? {
        FakeICloudStorageModel(album: album)
    }
}

final class DiskFileAccessTests: XCTestCase {

    private let keyA = PrivateKey(name: "keyA", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private let keyB = PrivateKey(name: "keyB", keyBytes: Array(repeating: 0x24, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private let plaintext = Data((0..<30000).map { UInt8($0 % 251) })

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFileAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        // The `storedKeysCalls` assertions below use "did the keychain get read"
        // as the observable proof that a discovery sweep ran. `DiskFileAccess`
        // holds the key library in a short-lived snapshot, which would make a
        // genuine second sweep read zero times and quietly turn those
        // assertions into no-ops. Zeroing the TTL keeps them measuring what they
        // were written to measure; `testStoredKeysSnapshotCollapsesRepeatQueries`
        // covers the caching itself.
        DiskFileAccess.storedKeysSnapshotTTL = 0
    }

    override func tearDownWithError() throws {
        DiskFileAccess.storedKeysSnapshotTTL = 1.0
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeDiskAccess(albumKey: PrivateKey, keyManager: DemoKeyManager) async -> DiskFileAccess {
        let album = Album(name: "DiskFileAccessTests-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: albumKey)
        let albumManager = DemoAlbumManager()
        albumManager.keyManager = keyManager
        let diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)
        return diskAccess
    }

    private func encryptFixture(with key: PrivateKey, id: String) async throws -> EncryptedMedia {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: id)
        let url = tempDirectory.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")
        let handler = SecretFileHandlerV2(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        return EncryptedMedia(source: url, mediaType: .photo, id: id)
    }

    // MARK: - Shared key resolution (stamp-on-open)

    func testDecryptToDataResolvesNonCurrentKey() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        guard case .data(let data) = decrypted.source else {
            return XCTFail("Expected in-memory data")
        }
        XCTAssertEqual(data, plaintext)
    }

    func testDecryptToURLResolvesNonCurrentKey() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let decrypted = try await diskAccess.loadMediaToURL(media: encrypted, progress: { _ in })

        let outputURL = try XCTUnwrap(decrypted.url)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        XCTAssertEqual(try Data(contentsOf: outputURL), plaintext)
    }

    /// Superseded `testDecryptFailsSameAsBeforeWhenNoKeyMatches`, which pinned
    /// the current-key fallback and the resulting generic `decryptError`. ENC-99
    /// exists to change exactly that: media needing an absent key must now be
    /// reported as such so the user can be offered the key, rather than being
    /// indistinguishable from a damaged file.
    func testMissingKeyReportedInsteadOfGenericDecryptError() async throws {
        let unstoredKey = PrivateKey(name: "unstored", keyBytes: Array(repeating: 0x99, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: unstoredKey, id: UUID().uuidString)

        do {
            _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })
            XCTFail("Expected decryption to fail")
        } catch let error as FileAccessError {
            guard case .missingKeyForMedia = error else {
                return XCTFail("Expected .missingKeyForMedia, got \(error)")
            }
        }
    }

    /// The other half of the distinction: a file whose *structure* is broken
    /// keeps failing through the decrypt path rather than being reported as a
    /// missing key. This covers the structural signal only — the fixture below
    /// is 28 bytes, so `FirstBlockProbe.init` gives up at the block-size read.
    /// Body damage on an unstamped file is a different story, pinned by
    /// `testUnstampedDamagedBodyIsReportedAsAMissingKey`.
    func testCorruptFileStillReportsDecryptErrorNotMissingKey() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyB, id: UUID().uuidString)
        guard case .url(let sourceURL) = encrypted.source else {
            return XCTFail("fixture must be file-backed")
        }
        try Data("not an encrypted file at all".utf8).write(to: sourceURL)

        do {
            _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })
            XCTFail("Expected decryption to fail")
        } catch let error as FileAccessError {
            XCTFail("A corrupt file must not be reported as a missing key, got \(error)")
        } catch {
            // Any non-FileAccessError failure is the pre-existing decrypt path.
        }
    }

    /// The gap the split does not close, pinned so a regression here is a
    /// deliberate choice rather than a surprise. A file with an intact prologue,
    /// stream header and block-size field, damaged ciphertext, and no stamp —
    /// the state of every iCloud Drive file, since `shouldStampFile` excludes
    /// them — reaches the user as a missing key, and they are sent to find a
    /// phrase that can never open it.
    ///
    /// Closing it needs a trustworthy record of the required key for non-local
    /// files; there is no cryptographic way to separate "wrong key" from
    /// "altered bytes" from the AEAD failure alone.
    func testUnstampedDamagedBodyIsReportedAsAMissingKey() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyB, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL), "the fixture must carry no stamp")

        // Flip bytes inside the first ciphertext block, leaving every structural
        // field readable, so the probe constructs and only the AEAD fails.
        // Offset 500 clears the prologue, the 24-byte stream header and the
        // 8-byte block-size field (which together end well below 200) and sits
        // far inside the ~20KB first block.
        var fileData = try Data(contentsOf: sourceURL)
        XCTAssertGreaterThan(fileData.count, 700, "the fixture must be larger than the damaged range")
        for index in 500..<700 {
            fileData[index] ^= 0xFF
        }
        try fileData.write(to: sourceURL)

        do {
            _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })
            XCTFail("Expected decryption to fail")
        } catch let error as FileAccessError {
            guard case .missingKeyForMedia(let requiredStampPrefix) = error else {
                return XCTFail("Expected .missingKeyForMedia, got \(error)")
            }
            XCTAssertNil(requiredStampPrefix, "an unstamped file names no key, so none may be shown")
        }
    }

    /// The grid's own path, and the one that decides which glyph a user sees.
    ///
    /// A thumbnail that needs an absent key must surface as `missingKeyForMedia`,
    /// not be retried as if it were simply absent. The retry decrypts the same
    /// media with the same key, so it can only fail — and when the media is not
    /// on this device it fails through the `.unreadable` current-key fallback
    /// with a generic error, which is how a CloudKit second device ended up
    /// showing the generic failure glyph for every locked item on the rig.
    func testPreviewNeedingAnAbsentKeyReportsMissingKeyNotAGenericFailure() async throws {
        let unstoredKey = PrivateKey(name: "unstored", keyBytes: Array(repeating: 0x99, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        // Media AND its preview both written under a key this device lacks, and
        // the media itself removed — a device that received only the thumbnail.
        let encrypted = try await encryptFixture(with: unstoredKey, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        let foreignAccess = await makeDiskAccess(albumKey: unstoredKey, keyManager: keyManager)
        // Written through `savePreview` rather than `createPreview`: the latter
        // renders a thumbnail from the bytes, and this fixture's payload is not
        // a decodable image. What matters here is only that the preview file
        // exists and is encrypted under the absent key.
        let thumbnail = CleartextMedia(source: plaintext, mediaType: .preview, id: encrypted.id)
        _ = try await foreignAccess.savePreview(preview: PreviewModel(thumbnailMedia: thumbnail),
                                                sourceMedia: encrypted)
        try FileManager.default.removeItem(at: sourceURL)

        do {
            _ = try await diskAccess.loadMediaPreview(for: encrypted)
            XCTFail("Expected the preview load to fail")
        } catch let error as FileAccessError {
            guard case .missingKeyForMedia = error else {
                return XCTFail("Expected .missingKeyForMedia, got \(error)")
            }
        } catch {
            XCTFail("A preview needing an absent key must report a missing key, got \(error)")
        }
    }

    // MARK: - Stamp-on-open (local-only gate)

    func testOpenStampsLocalFile() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL), "Fresh files are unstamped")

        _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        XCTAssertEqual(KeyStampSlot.readStamp(url: sourceURL), keyA.stampPrefix, "Open must stamp the confirmed key's prefix")
    }

    func testStaleStampRewrittenOnOpen() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        KeyStampSlot.writeStamp(keyB.stampPrefix, url: sourceURL)

        _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        XCTAssertEqual(KeyStampSlot.readStamp(url: sourceURL), keyA.stampPrefix, "A stale stamp must be corrected on open")
    }

    func testMatchingStampNotRewritten() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        KeyStampSlot.writeStamp(keyA.stampPrefix, url: sourceURL)

        let bytesBefore = try Data(contentsOf: sourceURL)
        // The attribute-modification date (ctime) changes on any write or
        // attribute restore, so an unchanged value proves no write happened.
        try await Task.sleep(nanoseconds: 50_000_000)
        let ctimeBefore = try sourceURL.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate

        _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        XCTAssertEqual(try Data(contentsOf: sourceURL), bytesBefore)
        let ctimeAfter = try sourceURL.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate
        XCTAssertEqual(ctimeBefore, ctimeAfter, "A matching stamp must not be rewritten")
    }

    func testICloudFileNeverStamped() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let album = Album(name: "DiskFileAccessTests-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: keyB)
        let albumManager = FakeICloudAlbumManager()
        albumManager.keyManager = keyManager
        let diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        let bytesBefore = try Data(contentsOf: sourceURL)

        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        guard case .data(let data) = decrypted.source else {
            return XCTFail("Expected in-memory data")
        }
        XCTAssertEqual(data, plaintext, "iCloud files still get discovery and decrypt")
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytesBefore, "iCloud files must never be written on open")
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL))
    }

    func testStampFailureDoesNotFailOpen() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sourceURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourceURL.path) }

        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        guard case .data(let data) = decrypted.source else {
            return XCTFail("Expected in-memory data")
        }
        XCTAssertEqual(data, plaintext, "A read-only file must still open normally")
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL), "The failed stamp write must leave the slot untouched")
    }

    // MARK: - Discovery memo

    /// iCloud-modeled access, so files stay unstamped and only the in-memory
    /// memo can spare repeated opens the discovery sweep.
    private func makeICloudDiskAccess(keyManager: DemoKeyManager) async -> DiskFileAccess {
        let album = Album(name: "DiskFileAccessTests-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: keyB)
        let albumManager = FakeICloudAlbumManager()
        albumManager.keyManager = keyManager
        let diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)
        return diskAccess
    }

    private func open(_ encrypted: EncryptedMedia, with diskAccess: DiskFileAccess) async throws -> Data {
        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })
        guard case .data(let data) = decrypted.source else {
            throw SecretFilesError.decryptError("Expected in-memory data")
        }
        return data
    }

    func testSecondOpenSkipsDiscovery() async throws {
        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeICloudDiskAccess(keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)

        let firstOpen = try await open(encrypted, with: diskAccess)
        XCTAssertEqual(firstOpen, plaintext)
        XCTAssertGreaterThanOrEqual(keyManager.storedKeysCalls, 1, "First open of an unstamped file runs discovery")
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL), "iCloud-modeled files stay unstamped")

        keyManager.storedKeysCalls = 0
        let secondOpen = try await open(encrypted, with: diskAccess)
        XCTAssertEqual(secondOpen, plaintext)
        XCTAssertEqual(keyManager.storedKeysCalls, 0, "Second open must resolve via the memo, with no discovery sweep")
    }

    func testStaleMemoFallsThroughToDiscovery() async throws {
        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeICloudDiskAccess(keyManager: keyManager)

        let id = UUID().uuidString
        let encrypted = try await encryptFixture(with: keyA, id: id)
        let sourceURL = try XCTUnwrap(encrypted.url)
        _ = try await open(encrypted, with: diskAccess)

        // Replace the file with one encrypted by a different key: the memo
        // entry for this media id is now stale.
        try FileManager.default.removeItem(at: sourceURL)
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: id)
        let handler = SecretFileHandlerV2(keyBytes: keyB.keyBytes, source: cleartext, targetURL: sourceURL)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())

        keyManager.storedKeysCalls = 0
        let reopened = try await open(encrypted, with: diskAccess)
        XCTAssertEqual(reopened, plaintext, "A stale memo must degrade to rediscovery, not a failed open")
        XCTAssertGreaterThanOrEqual(keyManager.storedKeysCalls, 1, "The stale memo entry must fall through to discovery")

        keyManager.storedKeysCalls = 0
        _ = try await open(encrypted, with: diskAccess)
        XCTAssertEqual(keyManager.storedKeysCalls, 0, "The memo must now map to the replacement key")
    }

    func testMemoNotConsultedAcrossInstances() async throws {
        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let firstAccess = await makeICloudDiskAccess(keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        _ = try await open(encrypted, with: firstAccess)

        let secondAccess = await makeICloudDiskAccess(keyManager: keyManager)
        keyManager.storedKeysCalls = 0
        _ = try await open(encrypted, with: secondAccess)
        XCTAssertGreaterThanOrEqual(keyManager.storedKeysCalls, 1, "A fresh instance starts with an empty memo — no static/global state")
    }

    // MARK: - Stored-key snapshot

    /// Sweeping an album must read the key library once, not once per file.
    /// `KeychainManager.storedKeys()` is a `SecItemCopyMatching` over every
    /// stored key with `kSecReturnData`; at one call per image it measured ~47ms
    /// of pure keychain traffic per 120-image album on an iPhone 12 Pro.
    func testStoredKeysSnapshotCollapsesRepeatQueries() async throws {
        DiskFileAccess.storedKeysSnapshotTTL = 1.0

        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeICloudDiskAccess(keyManager: keyManager)

        // Encrypted with a key the manager does not hold, so every open runs the
        // full sweep and none of them can be short-circuited by the memo.
        let foreign = PrivateKey(name: "foreign", keyBytes: Array(repeating: 0x5A, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        var media: [EncryptedMedia] = []
        for _ in 0..<8 {
            media.append(try await encryptFixture(with: foreign, id: UUID().uuidString))
        }

        keyManager.storedKeysCalls = 0
        for item in media {
            _ = try? await open(item, with: diskAccess)
        }
        XCTAssertEqual(keyManager.storedKeysCalls, 1,
                       "8 unresolvable opens inside the TTL must read the key library exactly once")
    }

    /// The snapshot must never outlive a key being added — that key exists
    /// precisely to open the media being looked at (ENC-99), and waiting out a
    /// TTL to notice it would show the user a missing-key album they have just
    /// supplied the key for.
    func testKeyLibraryDidGrowRetiresTheSnapshot() async throws {
        DiskFileAccess.storedKeysSnapshotTTL = 1.0

        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeICloudDiskAccess(keyManager: keyManager)

        let foreign = PrivateKey(name: "foreign", keyBytes: Array(repeating: 0x5B, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let first = try await encryptFixture(with: foreign, id: UUID().uuidString)
        let second = try await encryptFixture(with: foreign, id: UUID().uuidString)

        keyManager.storedKeysCalls = 0
        _ = try? await open(first, with: diskAccess)
        XCTAssertEqual(keyManager.storedKeysCalls, 1)

        NotificationCenter.default.post(name: .keyLibraryDidGrow, object: nil)
        // The notification is delivered synchronously on the posting thread, but
        // the observer is registered with a nil queue on first use; give the run
        // loop a turn so the generation bump is visible.
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try? await open(second, with: diskAccess)
        XCTAssertEqual(keyManager.storedKeysCalls, 2,
                       "a grown key library must force the next sweep to re-read, TTL notwithstanding")
    }

    // MARK: - Born-stamped saves

    /// A tiny real JPEG so `save`'s preview generation succeeds.
    private func makePhotoData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    func testSaveStampsNewLocalFile() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA
        let diskAccess = await makeDiskAccess(albumKey: keyA, keyManager: keyManager)

        let media = CleartextMedia(source: makePhotoData(), mediaType: .photo, id: UUID().uuidString)
        let encrypted = try await diskAccess.save(media: media, metadata: EncryptedFileMetadata(), progress: { _ in })
        let savedURL = try XCTUnwrap(encrypted?.url)
        defer { try? FileManager.default.removeItem(at: savedURL) }

        XCTAssertEqual(KeyStampSlot.readStamp(url: savedURL), keyA.stampPrefix, "New local files must be born stamped")
        XCTAssertEqual(try ExtendedAttributesUtil.getKeyUUID(for: savedURL), keyA.uuid, "The keyUUID xattr must still be written")
    }

    func testSaveDoesNotStampICloudFile() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA
        let album = Album(name: "DiskFileAccessTests-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: keyA)
        let albumManager = FakeICloudAlbumManager()
        albumManager.keyManager = keyManager
        let diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)

        let media = CleartextMedia(source: makePhotoData(), mediaType: .photo, id: UUID().uuidString)
        let encrypted = try await diskAccess.save(media: media, metadata: EncryptedFileMetadata(), progress: { _ in })
        let savedURL = try XCTUnwrap(encrypted?.url)
        defer { try? FileManager.default.removeItem(at: savedURL) }

        XCTAssertNil(KeyStampSlot.readStamp(url: savedURL), "iCloud saves must leave the slot zero")
        XCTAssertEqual(try ExtendedAttributesUtil.getKeyUUID(for: savedURL), keyA.uuid)
    }

    func testSavedFileOpensViaStampWithoutDiscovery() async throws {
        let keyManager = DemoKeyManager(keys: [keyB, keyA])
        keyManager.currentKey = keyA
        let diskAccess = await makeDiskAccess(albumKey: keyA, keyManager: keyManager)

        let media = CleartextMedia(source: makePhotoData(), mediaType: .photo, id: UUID().uuidString)
        let encrypted = try await diskAccess.save(media: media, metadata: EncryptedFileMetadata(), progress: { _ in })
        let savedURL = try XCTUnwrap(encrypted?.url)
        defer { try? FileManager.default.removeItem(at: savedURL) }

        var attempts: [String] = []
        let result = await KeyDiscovery.discoverKey(for: savedURL, keyManager: keyManager, onAttempt: { attempts.append($0.name) })
        XCTAssertEqual(attempts, ["keyA"], "A born-stamped file must resolve with a single test-decrypt, no sweep")
        XCTAssertEqual(result?.key, keyA)
        XCTAssertEqual(result?.stampMatched, true)
    }

    func testXattrHintStillHonored() async throws {
        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        try ExtendedAttributesUtil.setKeyUUID(keyA.uuid, for: sourceURL)

        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        guard case .data(let data) = decrypted.source else {
            return XCTFail("Expected in-memory data")
        }
        XCTAssertEqual(data, plaintext)
        // The hint used to be resolved via `keyManager.keyWith(uuid:)`, which is
        // a second full keychain query per file; discovery now resolves it
        // against the key snapshot it already holds, so there is no call to
        // count here. That the hint still ORDERS candidates ahead of the current
        // key is asserted directly, on attempt order, by
        // `KeyDiscoveryTests.testXattrHintOrderedBeforeCurrentKey`.
        XCTAssertTrue(keyManager.keyWithUUIDCalls.isEmpty,
                      "Resolving the xattr hint must not cost a second keychain query")
    }
    func testTotalStoredMediaCountCountsNormalPhoto() async throws {
        let fileManager = FileManager.default
        let testRoot = LocalStorageModel.albumsURL
            .appendingPathComponent("EncameraCoreTests")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let diskAccess = DiskFileAccess()
        let baseline = await diskAccess.totalStoredMediaCount()

        let photoID = UUID().uuidString
        let photoURL = testRoot.appendingPathComponent("\(photoID).\(MediaType.photo.encryptedFileExtension)")
        XCTAssertTrue(fileManager.createFile(atPath: photoURL.path, contents: Data()))

        let after = await diskAccess.totalStoredMediaCount()
        XCTAssertEqual(after - baseline, 1)
    }

    func testTotalStoredMediaCountCountsLivePhotoOnce() async throws {
        let fileManager = FileManager.default
        let testRoot = LocalStorageModel.albumsURL
            .appendingPathComponent("EncameraCoreTests")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let diskAccess = DiskFileAccess()
        let baseline = await diskAccess.totalStoredMediaCount()

        let liveID = UUID().uuidString
        let photoURL = testRoot.appendingPathComponent("\(liveID).\(MediaType.photo.encryptedFileExtension)")
        let videoURL = testRoot.appendingPathComponent("\(liveID).\(MediaType.video.encryptedFileExtension)")
        XCTAssertTrue(fileManager.createFile(atPath: photoURL.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: videoURL.path, contents: Data()))

        let after = await diskAccess.totalStoredMediaCount()
        XCTAssertEqual(after - baseline, 1)
    }
}
