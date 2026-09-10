import XCTest
@testable import EncameraCore

/// Format sniffing and the whole-item aggregates the info screen renders from.
///
/// Both are pure — no backend, no album — which is what makes the awkward cases
/// (a Live Photo whose two components disagree, "not cached" versus "cached and
/// empty") cheap enough to state exhaustively here rather than on a device.
final class MediaStorageDetailsTests: XCTestCase {

    private var tempDirectory: URL!
    private let key = [UInt8](repeating: 0x37, count: 32)

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaStorageDetailsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Format sniffing

    func testSniffsENC2FromItsMagic() throws {
        var bytes = Data(EncryptedFileFormat.magic)
        bytes.append(Data(repeating: 0, count: 64))
        XCTAssertEqual(EncryptedFormatVersion.sniff(headerBytes: bytes), .v2)
    }

    func testSniffsENC3FromItsMagic() throws {
        var bytes = Data(SeekableEncryptedHeader.magic)
        bytes.append(Data(repeating: 0, count: 64))
        XCTAssertEqual(EncryptedFormatVersion.sniff(headerBytes: bytes), .v3)
    }

    /// V1 carries no magic at all, so it is what remains once the two magics are
    /// excluded. A file whose first bytes happen to look like nothing in
    /// particular is V1, not "unknown".
    func testSniffsAnythingWithoutAMagicAsENC1() throws {
        let bytes = Data([0x9F, 0x01, 0xAB, 0x22] + Array(repeating: UInt8(0), count: 64))
        XCTAssertEqual(EncryptedFormatVersion.sniff(headerBytes: bytes), .v1)
    }

    /// A file too short to hold a magic names no format. Reporting V1 here would
    /// label a truncated or empty file as legacy media rather than as damage.
    func testSniffsTooShortAsUnknown() throws {
        XCTAssertNil(EncryptedFormatVersion.sniff(headerBytes: Data([0x45, 0x4E])))
        XCTAssertNil(EncryptedFormatVersion.sniff(headerBytes: Data()))
    }

    func testSniffsAbsentFileAsUnknown() throws {
        let missing = tempDirectory.appendingPathComponent("nope.encimage")
        XCTAssertNil(EncryptedFormatVersion.sniff(fileURL: missing))
    }

    /// The end-to-end statement: bytes a real writer produced classify as ENC3,
    /// and the header read off the same file reports the chunk count the info
    /// screen shows.
    func testSniffsARealENC3FileAndReadsItsChunkCount() throws {
        let plaintext = Data((0..<10_000).map { UInt8($0 % 251) })
        let source = tempDirectory.appendingPathComponent("source.bin")
        try plaintext.write(to: source)
        let destination = tempDirectory.appendingPathComponent("blob.encvideo")
        let written = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_000)
            .encrypt(source: source, destination: destination)

        XCTAssertEqual(EncryptedFormatVersion.sniff(fileURL: destination), .v3)
        XCTAssertEqual(written.chunkCount, 10)
        let read = try SeekableEncryptedHeader.read(fromFileAt: destination).header
        XCTAssertEqual(read.chunkCount, 10)
    }

    /// The header reader must survive a metadata section, which pushes the header
    /// past its fixed preamble — the case a fixed-size read would silently
    /// truncate.
    func testReadsAnENC3HeaderThatCarriesMetadata() throws {
        var metadata = EncryptedFileMetadata()
        metadata.originalFilename = "IMG_0655.MOV"
        let source = tempDirectory.appendingPathComponent("source.bin")
        try Data(repeating: 7, count: 5_000).write(to: source)
        let destination = tempDirectory.appendingPathComponent("blob.encvideo")
        let written = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_000)
            .encrypt(source: source,
                     destination: destination,
                     metadata: try SeekableEncryptedFormat.encodeMetadata(metadata))

        XCTAssertGreaterThan(written.encryptedMetadata.count, 0, "fixture must exercise the variable-length section")
        let read = try SeekableEncryptedHeader.read(fromFileAt: destination).header
        XCTAssertEqual(read.chunkCount, 5)
        XCTAssertEqual(read.headerLength, written.headerLength)
    }

    // MARK: - Aggregation

    private func component(_ type: MediaType,
                           remote: Int64? = nil,
                           local: Int64? = nil,
                           format: EncryptedFormatVersion? = nil,
                           chunks: Int? = nil) -> MediaStorageDetails.Component {
        MediaStorageDetails.Component(mediaType: type,
                                      remoteBytes: remote,
                                      localBytes: local,
                                      format: format,
                                      chunkCount: chunks)
    }

    func testSumsBytesAcrossALivePhotosTwoComponents() throws {
        let details = MediaStorageDetails(storageType: .cloudKit, components: [
            component(.photo, remote: 2_000, local: 2_000, format: .v2),
            component(.video, remote: 8_000, local: 8_000, format: .v2)
        ])
        XCTAssertEqual(details.remoteBytes, 10_000)
        XCTAssertEqual(details.localBytes, 10_000)
    }

    /// `nil` and `0` mean different things: nothing cached versus a cached empty
    /// file. Summing a `nil` as zero would report "0 bytes cached" for media that
    /// has never been downloaded, and the evict button would offer to remove it.
    func testUncachedComponentsReportNilRatherThanZero() throws {
        let details = MediaStorageDetails(storageType: .cloudKit, components: [
            component(.photo, remote: 2_000, local: nil, format: nil)
        ])
        XCTAssertNil(details.localBytes)
        XCTAssertFalse(details.canEvictLocalCopy)
    }

    /// A half-cached Live Photo reports the bytes it actually holds, and is
    /// evictable — there is something there to reclaim.
    func testPartiallyCachedItemReportsOnlyTheResidentBytes() throws {
        let details = MediaStorageDetails(storageType: .cloudKit, components: [
            component(.photo, remote: 2_000, local: 2_000, format: .v2),
            component(.video, remote: 8_000, local: nil, format: nil)
        ])
        XCTAssertEqual(details.localBytes, 2_000)
        XCTAssertTrue(details.canEvictLocalCopy)
    }

    /// A Live Photo can hold an ENC2 still beside an ENC3 movie. Naming one of
    /// them as "the" format would be a coin flip, so the row is omitted instead.
    func testMixedFormatsReportNoSingleFormat() throws {
        let details = MediaStorageDetails(storageType: .cloudKit, components: [
            component(.photo, format: .v2),
            component(.video, format: .v3, chunks: 12)
        ])
        XCTAssertNil(details.format)
        XCTAssertEqual(details.chunkCount, 12)
    }

    func testAgreeingComponentsReportTheSharedFormat() throws {
        let details = MediaStorageDetails(storageType: .cloudKit, components: [
            component(.photo, format: .v2),
            component(.video, format: .v2)
        ])
        XCTAssertEqual(details.format, .v2)
        XCTAssertNil(details.chunkCount, "nothing is chunked, so there is no chunk row")
    }

    /// A local album has one copy, and it is the media itself. Offering to evict
    /// it would be a delete wearing another name.
    func testLocalStorageIsNeitherRemotelyBackedNorEvictable() throws {
        let details = MediaStorageDetails(storageType: .local, components: [
            component(.photo, remote: nil, local: 4_000, format: .v2)
        ])
        XCTAssertFalse(details.isRemotelyBacked)
        XCTAssertFalse(details.canEvictLocalCopy)
        XCTAssertEqual(details.localBytes, 4_000)
        XCTAssertNil(details.remoteBytes)
    }

    func testCloudItemWithCachedBytesIsEvictable() throws {
        let details = MediaStorageDetails(storageType: .cloudKit, components: [
            component(.video, remote: 90_000, local: 90_000, format: .v3, chunks: 3)
        ])
        XCTAssertTrue(details.canEvictLocalCopy)
        XCTAssertEqual(details.format, .v3)
        XCTAssertEqual(details.chunkCount, 3)
    }

    func testItemWithNoComponentsReportsNothing() throws {
        let details = MediaStorageDetails(storageType: .cloudKit, components: [])
        XCTAssertNil(details.remoteBytes)
        XCTAssertNil(details.localBytes)
        XCTAssertNil(details.format)
        XCTAssertNil(details.chunkCount)
        XCTAssertFalse(details.canEvictLocalCopy)
    }
}
