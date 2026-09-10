import XCTest
@testable import EncameraCore

/// `DiskMediaBackend.storageDetails` against real files in a real album
/// directory: the sizes are the files' own and the format is sniffed off their
/// bytes, so this is where the mapping from "what is on disk" to "what the info
/// screen shows" is pinned down.
final class DiskMediaBackendStorageDetailsTests: XCTestCase {

    private let albumKey = PrivateKey(name: "album",
                                      keyBytes: Array(repeating: 0x51, count: 32),
                                      creationDate: Date(timeIntervalSince1970: 0))

    private func makeBackend() async -> (DiskMediaBackend, DataStorageModel) {
        let album = Album(name: "DiskMediaBackendStorageDetailsTests-\(UUID().uuidString)",
                          storageOption: .local,
                          creationDate: Date(),
                          key: albumKey)
        let albumManager = DemoAlbumManager()
        albumManager.keyManager = DemoKeyManager(keys: [albumKey])
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        let model = albumManager.storageModel(for: album)!
        try? FileManager.default.createDirectory(at: model.baseURL, withIntermediateDirectories: true)
        return (backend, model)
    }

    /// Writes `bytes` to the album path the backend will look for `id` at, so the
    /// test never has to guess the naming scheme.
    @discardableResult
    private func writeComponent(_ bytes: Data,
                                id: String,
                                type: MediaType,
                                model: DataStorageModel) throws -> URL {
        let url = model.driveURLForMedia(withID: id, type: type)
        try bytes.write(to: url)
        return url
    }

    private func media(id: String, types: [MediaType], model: DataStorageModel) throws -> InteractableMedia<EncryptedMedia> {
        try InteractableMedia(underlyingMedia: types.map {
            EncryptedMedia(source: .url(model.driveURLForMedia(withID: id, type: $0)), mediaType: $0, id: id)
        })
    }

    private func enc2Bytes(count: Int) -> Data {
        var data = Data(EncryptedFileFormat.magic)
        data.append(Data(repeating: 0xAB, count: count - EncryptedFileFormat.magicSize))
        return data
    }

    // MARK: -

    func testReportsOnDiskSizeAndSniffedFormatForALocalAlbum() async throws {
        let (backend, model) = await makeBackend()
        let id = UUID().uuidString
        try writeComponent(enc2Bytes(count: 4_096), id: id, type: .photo, model: model)

        let details = await backend.storageDetails(for: try media(id: id, types: [.photo], model: model))

        XCTAssertEqual(details?.storageType, .local)
        XCTAssertEqual(details?.localBytes, 4_096)
        XCTAssertEqual(details?.format, .v2)
        XCTAssertNil(details?.chunkCount)
    }

    /// A local album has no second copy, so the info screen must not offer to
    /// "remove the cached copy" — the only copy is the media.
    func testLocalAlbumReportsNoRemoteSideAndIsNotEvictable() async throws {
        let (backend, model) = await makeBackend()
        let id = UUID().uuidString
        try writeComponent(enc2Bytes(count: 1_024), id: id, type: .photo, model: model)

        let details = await backend.storageDetails(for: try media(id: id, types: [.photo], model: model))

        XCTAssertNil(details?.remoteBytes)
        XCTAssertFalse(details?.isRemotelyBacked ?? true)
        XCTAssertFalse(details?.canEvictLocalCopy ?? true)
    }

    func testRefusesToEvictTheOnlyCopyInALocalAlbum() async throws {
        let (backend, model) = await makeBackend()
        let id = UUID().uuidString
        let url = try writeComponent(enc2Bytes(count: 1_024), id: id, type: .photo, model: model)

        do {
            try await backend.evictLocalCopy(for: try media(id: id, types: [.photo], model: model))
            XCTFail("evicting a local album's only copy must not be treated as a no-op success")
        } catch FileAccessError.localCopyNotEvictable {
            // expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the refused eviction must not have touched the file")
    }

    /// A real ENC3 file must report ENC3 and the chunk count from its own header,
    /// which is the pair of rows the whole feature exists to show. The fixture
    /// carries embedded metadata because `DiskFileAccess.save` writes it for every
    /// camera recording, which pushes the header past its fixed preamble.
    func testReportsENC3AndItsChunkCountForAChunkedVideo() async throws {
        let (backend, model) = await makeBackend()
        let id = UUID().uuidString
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc3-source-\(UUID().uuidString).bin")
        try Data((0..<9_000).map { UInt8($0 % 251) }).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        metadata.originalMediaType = "video"
        metadata.originalExtension = "mov"
        metadata.originalFilename = "camera-recording.mov"
        let metadataJSON = try SeekableEncryptedFormat.encodeMetadata(metadata)

        let written = try SeekableEncryptedWriter(keyBytes: albumKey.keyBytes, chunkSize: 1_000)
            .encrypt(source: source,
                     destination: model.driveURLForMedia(withID: id, type: .video),
                     metadata: metadataJSON)
        XCTAssertFalse(written.encryptedMetadata.isEmpty,
                       "fixture must exercise the variable-length metadata section")

        let details = await backend.storageDetails(for: try media(id: id, types: [.video], model: model))

        XCTAssertEqual(details?.format, .v3)
        XCTAssertEqual(details?.chunkCount, written.chunkCount)
        XCTAssertEqual(details?.chunkCount, 9)
    }

    /// A Live Photo is two files, and the screen shows their combined footprint.
    func testSumsBothComponentsOfALivePhoto() async throws {
        let (backend, model) = await makeBackend()
        let id = UUID().uuidString
        try writeComponent(enc2Bytes(count: 1_000), id: id, type: .photo, model: model)
        try writeComponent(enc2Bytes(count: 3_000), id: id, type: .video, model: model)

        let details = await backend.storageDetails(for: try media(id: id, types: [.photo, .video], model: model))

        XCTAssertEqual(details?.components.count, 2)
        XCTAssertEqual(details?.localBytes, 4_000)
        XCTAssertEqual(details?.format, .v2)
    }

    /// An index entry can outlive its file. The screen must then say nothing
    /// rather than report a zero-byte ENC1.
    func testMissingFileReportsNoSizeAndNoFormat() async throws {
        let (backend, model) = await makeBackend()
        let id = UUID().uuidString

        let details = await backend.storageDetails(for: try media(id: id, types: [.photo], model: model))

        XCTAssertEqual(details?.components.count, 1)
        XCTAssertNil(details?.localBytes)
        XCTAssertNil(details?.format)
    }
}
