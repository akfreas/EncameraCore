//
//  SeekableEncryptedFormatTests.swift
//  EncameraCoreTests
//
//  Covers the two claims ENC3 exists to make: a plaintext byte range can be
//  decrypted by touching only the chunks it overlaps, and the position binding in
//  the AAD makes a reordered / truncated / spliced file fail to authenticate.
//
//  The tamper cases matter more than the round trip. Independently-encrypted
//  chunks are exactly the construction that *looks* fine while being trivially
//  rearrangeable, and ENC2's ratchet used to rule that out for free — so every
//  one of those attacks gets an explicit test rather than a comment.
//

import XCTest
import Sodium
@testable import EncameraCore

final class SeekableEncryptedFormatTests: XCTestCase {

    private let key = [UInt8](repeating: 0x42, count: 32)
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc3-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Deterministic pseudo-random bytes — compressible fixtures would hide
    /// off-by-one slicing bugs that random-looking data exposes immediately.
    private func fixture(bytes count: Int) -> Data {
        var data = Data(capacity: count)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    private func writeFixture(_ data: Data, name: String = "source.bin") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Geometry

    func testGeometryChunkCountAndSizes() {
        let geo = SeekableChunkGeometry(chunkSize: 1000, plaintextLength: 2500, headerLength: 40)
        XCTAssertEqual(geo.chunkCount, 3)
        XCTAssertEqual(geo.plaintextSize(ofChunk: 0), 1000)
        XCTAssertEqual(geo.plaintextSize(ofChunk: 2), 500)
        XCTAssertEqual(geo.ciphertextSize(ofChunk: 0), 1000 + SeekableChunkGeometry.chunkOverhead)
        XCTAssertEqual(geo.ciphertextSize(ofChunk: 2), 500 + SeekableChunkGeometry.chunkOverhead)
    }

    func testGeometryExactMultipleHasNoEmptyTrailingChunk() {
        let geo = SeekableChunkGeometry(chunkSize: 1000, plaintextLength: 2000, headerLength: 0)
        XCTAssertEqual(geo.chunkCount, 2)
        XCTAssertEqual(geo.plaintextSize(ofChunk: 1), 1000)
    }

    func testGeometryEmptyFile() {
        let geo = SeekableChunkGeometry(chunkSize: 1000, plaintextLength: 0, headerLength: 40)
        XCTAssertEqual(geo.chunkCount, 0)
        XCTAssertEqual(geo.totalCiphertextLength, 40)
    }

    func testGeometryOffsetsAreContiguous() {
        let geo = SeekableChunkGeometry(chunkSize: 1000, plaintextLength: 2500, headerLength: 40)
        XCTAssertEqual(geo.ciphertextOffset(ofChunk: 0), 40)
        XCTAssertEqual(geo.ciphertextOffset(ofChunk: 1), 40 + 1000 + SeekableChunkGeometry.chunkOverhead)
        // Every chunk starts exactly where the previous one ended.
        for i in 0..<(geo.chunkCount - 1) {
            XCTAssertEqual(geo.ciphertextOffset(ofChunk: i) + geo.ciphertextSize(ofChunk: i),
                           geo.ciphertextOffset(ofChunk: i + 1))
        }
    }

    func testChunkRangeForPlaintextRange() {
        let geo = SeekableChunkGeometry(chunkSize: 1000, plaintextLength: 5000, headerLength: 0)
        XCTAssertEqual(geo.chunkRange(forPlaintextRange: 0..<1), 0..<1)
        XCTAssertEqual(geo.chunkRange(forPlaintextRange: 999..<1001), 0..<2)
        XCTAssertEqual(geo.chunkRange(forPlaintextRange: 1000..<2000), 1..<2)
        XCTAssertEqual(geo.chunkRange(forPlaintextRange: 4500..<9000), 4..<5, "must clamp past EOF")
        XCTAssertEqual(geo.chunkRange(forPlaintextRange: 6000..<7000), 0..<0, "entirely past EOF is empty")
    }

    // MARK: - Round trip

    func testRoundTripWholeFile() async throws {
        let plaintext = fixture(bytes: 10_000)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("out.enc3")

        let writer = SeekableEncryptedWriter(keyBytes: key, chunkSize: 1024)
        let header = try writer.encrypt(source: source, destination: dest)
        XCTAssertEqual(header.chunkCount, 10)
        XCTAssertEqual(header.plaintextLength, 10_000)

        let reader = try SeekableEncryptedReader.forFile(dest, keyBytes: key)
        let all = try await reader.plaintext(range: 0..<10_000)
        XCTAssertEqual(all, plaintext)
    }

    func testOnDiskSizeMatchesGeometry() throws {
        let plaintext = fixture(bytes: 7_777)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("out.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1024)
            .encrypt(source: source, destination: dest)

        let actual = dest.fileSizeBytes().map(Int.init)
        XCTAssertEqual(actual, header.geometry.totalCiphertextLength,
                       "geometry must predict the exact file size or every offset is wrong")
    }

    func testDecryptToFileMatchesOriginal() async throws {
        let plaintext = fixture(bytes: 9_001)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("out.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 512).encrypt(source: source, destination: dest)

        let out = tempDir.appendingPathComponent("roundtrip.bin")
        let reader = try SeekableEncryptedReader.forFile(dest, keyBytes: key)
        try await reader.decryptToFile(destination: out)
        XCTAssertEqual(try Data(contentsOf: out), plaintext)
    }

    func testEmptyFileRoundTrips() async throws {
        let source = try writeFixture(Data())
        let dest = tempDir.appendingPathComponent("empty.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1024)
            .encrypt(source: source, destination: dest)
        XCTAssertEqual(header.chunkCount, 0)

        let reader = try SeekableEncryptedReader.forFile(dest, keyBytes: key)
        let out = try await reader.plaintext(range: 0..<10)
        XCTAssertEqual(out, Data())
    }

    // MARK: - Random access (the point of the format)

    func testEveryByteRangeMatchesTheOriginal() async throws {
        let plaintext = fixture(bytes: 4_096)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("out.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 256).encrypt(source: source, destination: dest)
        let reader = try SeekableEncryptedReader.forFile(dest, keyBytes: key)

        // Ranges chosen to straddle every interesting boundary: chunk starts, chunk
        // ends, single bytes, whole-chunk spans and multi-chunk spans.
        let ranges: [Range<Int>] = [
            0..<1, 0..<256, 255..<257, 256..<512, 1..<1023,
            700..<1400, 4_095..<4_096, 0..<4_096, 3_000..<4_096
        ]
        for range in ranges {
            let got = try await reader.plaintext(range: range)
            XCTAssertEqual(got, plaintext.subdata(in: range), "range \(range) mismatched")
        }
    }

    func testSeekFetchesOnlyTheOverlappingChunks() async throws {
        let plaintext = fixture(bytes: 100_000)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("out.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 10_000)
            .encrypt(source: source, destination: dest)

        // The product claim: a read in the middle of the file must not touch chunk 0.
        let counting = CountingChunkProvider(
            wrapped: FileChunkProvider(fileURL: dest, geometry: header.geometry))
        let reader = SeekableEncryptedReader(keyBytes: key, header: header, provider: counting)

        let got = try await reader.plaintext(range: 50_000..<50_100)
        XCTAssertEqual(got, plaintext.subdata(in: 50_000..<50_100))
        let requested = await counting.requested
        XCTAssertEqual(requested, [5],
                       "a 100-byte read at 50k must fetch exactly one chunk, not the file")
    }

    func testCrossChunkReadFetchesBothChunksOnly() async throws {
        let plaintext = fixture(bytes: 100_000)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("out.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 10_000)
            .encrypt(source: source, destination: dest)

        let counting = CountingChunkProvider(
            wrapped: FileChunkProvider(fileURL: dest, geometry: header.geometry))
        let reader = SeekableEncryptedReader(keyBytes: key, header: header, provider: counting)

        _ = try await reader.plaintext(range: 19_990..<20_010)
        let requested = await counting.requested
        XCTAssertEqual(requested, [1, 2])
    }

    // MARK: - Metadata

    func testMetadataRoundTrips() async throws {
        let plaintext = fixture(bytes: 2_048)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("out.enc3")
        let metadata = Data(#"{"width":1920,"height":1080}"#.utf8)
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 512)
            .encrypt(source: source, destination: dest, metadata: metadata)

        let reader = try SeekableEncryptedReader.forFile(dest, keyBytes: key)
        XCTAssertEqual(try reader.metadata(), metadata)
        // Metadata shifts the header, so payload offsets must still line up.
        let payload = try await reader.plaintext(range: 0..<2_048)
        XCTAssertEqual(payload, plaintext)
    }

    /// The ENC3 header's metadata JSON must be byte-identical to the JSON the v2
    /// metadata section carries, so re-encrypting a file between the two formats
    /// preserves its metadata bytes exactly. Both sides encode through
    /// `EncryptedMetadataHandler`; this fails the moment one of them stops.
    func testENC3MetadataEncodingMatchesENC2ByteForByte() throws {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        metadata.encryptionDate = Date(timeIntervalSince1970: 1_700_000_123)
        metadata.originalFilename = "IMG_0042.HEIC"
        metadata.originalMediaType = "photo"
        metadata.originalFileSize = 4_194_304
        metadata.dimensions = .init(width: 4032, height: 3024)
        metadata.camera = .init(deviceMake: "Apple", deviceModel: "iPhone 17 Pro", iso: 100)
        metadata.location = .init(
            latitude: 52.52,
            longitude: 13.405,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        metadata.tags = ["beta", "alpha"]
        metadata.customFields = ["zulu": "1", "alfa": "2"]

        let enc3JSON = try SeekableEncryptedFormat.encodeMetadata(metadata)

        // The v2 section is sealed, so unseal it to compare the JSON it actually wrote.
        let sealed = try EncryptedMetadataHandler().encryptMetadata(metadata, keyBytes: key)
        let streamHeader = Array(sealed.prefix(EncryptedFileFormat.streamHeaderSize))
        let cipherText = Array(sealed.dropFirst(EncryptedFileFormat.streamHeaderSize))
        let pull = try XCTUnwrap(Sodium().secretStream.xchacha20poly1305.initPull(
            secretKey: key,
            header: streamHeader
        ))
        let (plaintextJSON, _) = try XCTUnwrap(pull.pull(cipherText: cipherText))
        let enc2JSON = Data(plaintextJSON)

        XCTAssertEqual(
            String(data: enc3JSON, encoding: .utf8),
            String(data: enc2JSON, encoding: .utf8),
            "ENC3 metadata JSON diverged from the v2 encoding"
        )
        XCTAssertEqual(enc3JSON, enc2JSON)
        XCTAssertEqual(try SeekableEncryptedFormat.decodeMetadata(enc2JSON), metadata)
    }

    // MARK: - Plaintext cache

    /// The repeat read must cost no decrypt and still hand back the same bytes.
    /// `PoisonAfterFirstServeProvider` makes the two halves inseparable: a reader
    /// that decrypts chunk 0 twice sees corrupted ciphertext the second time and
    /// throws, so passing means the bytes came from the cache — and they are
    /// asserted against an independent decrypt of the same file.
    func testRepeatedReadsOfTheSameChunkDecryptOnceAndReturnIdenticalBytes() async throws {
        let plaintext = fixture(bytes: 4_096)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("cached.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_024)
            .encrypt(source: source, destination: dest)

        let spy = PoisonAfterFirstServeProvider(
            wrapped: FileChunkProvider(fileURL: dest, geometry: header.geometry))
        let reader = SeekableEncryptedReader(keyBytes: key, header: header, provider: spy)

        let first = try await reader.plaintext(range: 0..<600)
        let second = try await reader.plaintext(range: 400..<1_024)
        XCTAssertEqual(first, plaintext.subdata(in: 0..<600))
        XCTAssertEqual(second, plaintext.subdata(in: 400..<1_024))

        let servedAfterChunkZero = await spy.served
        XCTAssertEqual(servedAfterChunkZero, [0], "the second read of chunk 0 must not decrypt again")

        // A different chunk must not be answered with the cached one.
        let nextChunk = try await reader.plaintextChunk(at: 1)
        XCTAssertEqual(nextChunk, plaintext.subdata(in: 1_024..<2_048))

        let fresh = try SeekableEncryptedReader.forFile(dest, keyBytes: key)
        let cachedChunkZero = try await reader.plaintextChunk(at: 0)
        let independentChunkZero = try await fresh.plaintextChunk(at: 0)
        XCTAssertEqual(cachedChunkZero, independentChunkZero)
        XCTAssertEqual(cachedChunkZero, plaintext.subdata(in: 0..<1_024))
    }

    /// The cache is two entries, so a 4 GB video costs two chunks of plaintext and
    /// not a growing fraction of the file.
    func testPlaintextCacheHoldsAtMostTwoChunks() async throws {
        let source = try writeFixture(fixture(bytes: 4_096))
        let dest = tempDir.appendingPathComponent("bounded.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_024)
            .encrypt(source: source, destination: dest)

        let counting = CountingChunkProvider(
            wrapped: FileChunkProvider(fileURL: dest, geometry: header.geometry))
        let reader = SeekableEncryptedReader(keyBytes: key, header: header, provider: counting)

        for index in [0, 1, 2, 1, 0] {
            _ = try await reader.plaintextChunk(at: index)
        }
        let requested = await counting.requested
        XCTAssertEqual(requested, [0, 1, 2, 0], "chunk 1 stays cached, chunk 0 is evicted")
    }

    /// The cache lives on the reader, next to the key and header it was decrypted
    /// with, so a second reader over the same ciphertext gets none of it. Otherwise
    /// a wrong key would be handed bytes it never authenticated.
    func testACachedChunkIsNeverServedToAReaderWithADifferentKey() async throws {
        let source = try writeFixture(fixture(bytes: 2_048))
        let dest = tempDir.appendingPathComponent("shared-provider.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_024)
            .encrypt(source: source, destination: dest)

        let provider = FileChunkProvider(fileURL: dest, geometry: header.geometry)
        let rightReader = SeekableEncryptedReader(keyBytes: key, header: header, provider: provider)
        _ = try await rightReader.plaintextChunk(at: 0)

        let wrongReader = SeekableEncryptedReader(
            keyBytes: [UInt8](repeating: 0x43, count: 32), header: header, provider: provider)
        await XCTAssertThrowsErrorAsync(try await wrongReader.plaintextChunk(at: 0)) { error in
            XCTAssertEqual(error as? SeekableFormatError, .chunkAuthenticationFailed(index: 0))
        }
    }

    /// Same key, same geometry, different files: chunk 0 of one must never come out
    /// of the other's reader.
    func testACachedChunkIsNeverServedToAReaderOverADifferentFile() async throws {
        let plaintextA = fixture(bytes: 2_048)
        let plaintextB = Data(plaintextA.reversed())
        let destA = tempDir.appendingPathComponent("a.enc3")
        let destB = tempDir.appendingPathComponent("b.enc3")
        let writer = SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_024)
        try writer.encrypt(source: try writeFixture(plaintextA, name: "a.bin"), destination: destA)
        try writer.encrypt(source: try writeFixture(plaintextB, name: "b.bin"), destination: destB)

        let readerA = try SeekableEncryptedReader.forFile(destA, keyBytes: key)
        let readerB = try SeekableEncryptedReader.forFile(destB, keyBytes: key)
        _ = try await readerA.plaintextChunk(at: 0)

        let fromB = try await readerB.plaintextChunk(at: 0)
        XCTAssertEqual(fromB, plaintextB.subdata(in: 0..<1_024))
        XCTAssertNotEqual(fromB, plaintextA.subdata(in: 0..<1_024))
    }

    /// Concurrent range requests are how AVFoundation drives the reader, so the
    /// cache has to survive them: same bytes out of every task, no crash.
    func testConcurrentReadsOfTheSameChunkAreConsistent() async throws {
        let plaintext = fixture(bytes: 8_192)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("concurrent.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_024)
            .encrypt(source: source, destination: dest)
        let reader = try SeekableEncryptedReader.forFile(dest, keyBytes: key)

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for iteration in 0..<64 {
                let index = iteration % 8
                group.addTask {
                    let bytes = try await reader.plaintextChunk(at: index)
                    return (index, bytes)
                }
            }
            for try await (index, bytes) in group {
                XCTAssertEqual(bytes, plaintext.subdata(in: (index * 1_024)..<((index + 1) * 1_024)))
            }
        }
    }

    // MARK: - Tamper resistance

    func testWrongKeyFailsToAuthenticate() async throws {
        let source = try writeFixture(fixture(bytes: 2_048))
        let dest = tempDir.appendingPathComponent("out.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 512)
            .encrypt(source: source, destination: dest)

        let wrongKey = [UInt8](repeating: 0x43, count: 32)
        let reader = SeekableEncryptedReader(
            keyBytes: wrongKey, header: header,
            provider: FileChunkProvider(fileURL: dest, geometry: header.geometry))
        await XCTAssertThrowsErrorAsync(try await reader.plaintextChunk(at: 0))
    }

    func testReorderedChunksFailToAuthenticate() async throws {
        let source = try writeFixture(fixture(bytes: 4_096))
        let dest = tempDir.appendingPathComponent("out.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_024)
            .encrypt(source: source, destination: dest)

        // Serve chunk 2's bytes when chunk 1 is asked for. Both are individually
        // valid ciphertexts under the right key — only the AAD's index binding
        // rejects this.
        let swapping = SwappingChunkProvider(
            wrapped: FileChunkProvider(fileURL: dest, geometry: header.geometry),
            serve: [1: 2])
        let reader = SeekableEncryptedReader(keyBytes: key, header: header, provider: swapping)

        await XCTAssertNoThrowAsync(try await reader.plaintextChunk(at: 0))
        await XCTAssertThrowsErrorAsync(try await reader.plaintextChunk(at: 1)) { error in
            XCTAssertEqual(error as? SeekableFormatError, .chunkAuthenticationFailed(index: 1))
        }
    }

    func testTruncatedFileFailsToAuthenticate() async throws {
        let source = try writeFixture(fixture(bytes: 4_096))
        let dest = tempDir.appendingPathComponent("out.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_024)
            .encrypt(source: source, destination: dest)
        XCTAssertEqual(header.chunkCount, 4)

        // An attacker drops the last chunk and rewrites the header to match. Every
        // surviving chunk is a valid ciphertext, but they were sealed with
        // chunkCount=4 in the AAD, so claiming 3 breaks authentication.
        let lyingHeader = SeekableEncryptedHeader(chunkSize: header.chunkSize,
                                                  plaintextLength: 3_072,
                                                  chunkCount: 3,
                                                  fileID: header.fileID,
                                                  encryptedMetadata: header.encryptedMetadata)
        let reader = SeekableEncryptedReader(
            keyBytes: key, header: lyingHeader,
            provider: FileChunkProvider(fileURL: dest, geometry: header.geometry))
        await XCTAssertThrowsErrorAsync(try await reader.plaintextChunk(at: 0))
    }

    /// The case that produced the `fileID` field. Two files of identical length and
    /// chunk size, encrypted under the SAME key — which is the normal situation in
    /// Encamera, where every item in an album shares the album key. Without a
    /// per-file identity in the AAD, chunk 2 of B is a byte-for-byte valid chunk 2
    /// of A and the swap authenticates silently.
    func testChunkSplicedFromAnotherFileUnderTheSameKeyFailsToAuthenticate() async throws {
        let sourceA = try writeFixture(fixture(bytes: 4_096), name: "a.bin")
        var reversed = Data(try Data(contentsOf: sourceA).reversed())
        reversed[0] ^= 0x01
        let sourceB = try writeFixture(reversed, name: "b.bin")

        let destA = tempDir.appendingPathComponent("a.enc3")
        let destB = tempDir.appendingPathComponent("b.enc3")
        let writer = SeekableEncryptedWriter(keyBytes: key, chunkSize: 1_024)
        let headerA = try writer.encrypt(source: sourceA, destination: destA)
        let headerB = try writer.encrypt(source: sourceB, destination: destB)

        XCTAssertNotEqual(headerA.fileID, headerB.fileID, "each file must get its own identity")
        XCTAssertEqual(headerA.plaintextLength, headerB.plaintextLength)
        XCTAssertEqual(headerA.chunkCount, headerB.chunkCount)

        let spliced = ForeignChunkProvider(
            local: FileChunkProvider(fileURL: destA, geometry: headerA.geometry),
            foreign: FileChunkProvider(fileURL: destB, geometry: headerB.geometry),
            foreignIndices: [2])
        let reader = SeekableEncryptedReader(keyBytes: key, header: headerA, provider: spliced)

        await XCTAssertNoThrowAsync(try await reader.plaintextChunk(at: 1))
        await XCTAssertThrowsErrorAsync(try await reader.plaintextChunk(at: 2)) { error in
            XCTAssertEqual(error as? SeekableFormatError, .chunkAuthenticationFailed(index: 2))
        }
    }

    func testCorruptedByteFailsToAuthenticate() async throws {
        let source = try writeFixture(fixture(bytes: 2_048))
        let dest = tempDir.appendingPathComponent("out.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: 512)
            .encrypt(source: source, destination: dest)

        var bytes = try Data(contentsOf: dest)
        let target = header.geometry.ciphertextOffset(ofChunk: 1) + 40
        bytes[target] ^= 0xFF
        try bytes.write(to: dest)

        let reader = try SeekableEncryptedReader.forFile(dest, keyBytes: key)
        await XCTAssertNoThrowAsync(try await reader.plaintextChunk(at: 0))
        await XCTAssertThrowsErrorAsync(try await reader.plaintextChunk(at: 1))
    }

    // MARK: - Format sniffing

    func testSniffDistinguishesENC3FromENC2() throws {
        let source = try writeFixture(fixture(bytes: 1_024))
        let dest = tempDir.appendingPathComponent("out.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 512).encrypt(source: source, destination: dest)
        XCTAssertTrue(SeekableEncryptedHeader.isSeekableFormat(fileURL: dest))

        // An ENC2 file must not be mistaken for ENC3 — that misroute is exactly how
        // ENC-135 made migrated media undecryptable.
        let enc2 = tempDir.appendingPathComponent("legacy.enc2")
        var legacy = Data(EncryptedFileFormat.magic)
        legacy.append(Data(repeating: 0, count: 64))
        try legacy.write(to: enc2)
        XCTAssertFalse(SeekableEncryptedHeader.isSeekableFormat(fileURL: enc2))
    }

    func testDecodeRejectsForeignMagic() {
        var data = Data("XXXX".utf8)
        data.append(Data(repeating: 0, count: SeekableEncryptedHeader.fixedSize - 4))
        XCTAssertThrowsError(try SeekableEncryptedHeader.decode(data)) { error in
            XCTAssertEqual(error as? SeekableFormatError, .notSeekableFormat)
        }
    }

    // MARK: - Header-only parsing

    /// The metadata section is variable-length, so a header-only caller that
    /// misreads its length lands mid-payload. Metadata-bearing on purpose: with an
    /// empty section every parse agrees at `fixedSize` and the bug hides.
    func testContentOffsetMatchesHeaderLengthOnMetadataBearingFile() async throws {
        let plaintext = fixture(bytes: 2_048)
        let source = try writeFixture(plaintext)
        let dest = tempDir.appendingPathComponent("out.enc3")
        let metadata = Data(#"{"width":1920,"height":1080}"#.utf8)
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 512)
            .encrypt(source: source, destination: dest, metadata: metadata)

        let reader = try SeekableEncryptedReader.forFile(dest, keyBytes: key)
        let encryptedMetadata = reader.header.encryptedMetadata
        XCTAssertGreaterThan(encryptedMetadata.count, 0, "fixture must carry a metadata section")

        let offset = try EncryptedMetadataHandler().contentOffset(for: dest)
        XCTAssertEqual(offset, UInt64(SeekableEncryptedHeader.fixedSize + encryptedMetadata.count))
        XCTAssertEqual(offset, UInt64(reader.header.headerLength))
        XCTAssertEqual(offset, UInt64(reader.geometry.ciphertextOffset(ofChunk: 0)))
    }

    func testFirstBlockProbeAuthenticatesChunkZeroOfMetadataBearingFile() async throws {
        let source = try writeFixture(fixture(bytes: 2_048))
        let dest = tempDir.appendingPathComponent("probe.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 512)
            .encrypt(source: source, destination: dest, metadata: Data(#"{"width":1920}"#.utf8))

        let right = PrivateKey(name: "right", keyBytes: key, creationDate: Date(timeIntervalSince1970: 0))
        let wrong = PrivateKey(name: "wrong", keyBytes: [UInt8](repeating: 0x43, count: 32),
                               creationDate: Date(timeIntervalSince1970: 0))
        let proved = await KeyDiscovery.proveFirstBlock(of: dest, with: right)
        XCTAssertEqual(proved, .proved)
        let disproved = await KeyDiscovery.proveFirstBlock(of: dest, with: wrong)
        XCTAssertEqual(disproved, .disproved)
    }
}

// MARK: - Test doubles

/// Records which chunk indices were asked for, so a test can assert that a seek
/// touched only the chunks it needed.
actor CountingChunkProvider: SeekableChunkProviding {
    private let wrapped: SeekableChunkProviding
    private(set) var requested: [Int] = []

    init(wrapped: SeekableChunkProviding) { self.wrapped = wrapped }

    func ciphertextChunk(at index: Int) async throws -> Data {
        requested.append(index)
        return try await wrapped.ciphertextChunk(at: index)
    }
}

/// Serves each index correctly once, then corrupts it. A reader that decrypts the
/// same chunk twice fails to authenticate the second time, so a passing repeat read
/// proves the bytes came from the plaintext cache rather than a second decrypt.
actor PoisonAfterFirstServeProvider: SeekableChunkProviding {
    private let wrapped: SeekableChunkProviding
    private(set) var served: [Int] = []

    init(wrapped: SeekableChunkProviding) { self.wrapped = wrapped }

    func ciphertextChunk(at index: Int) async throws -> Data {
        var data = try await wrapped.ciphertextChunk(at: index)
        let poison = served.contains(index)
        served.append(index)
        if poison {
            data[data.startIndex + 32] ^= 0xFF
        }
        return data
    }
}

/// Serves chunk `serve[i]`'s bytes whenever chunk `i` is requested.
struct SwappingChunkProvider: SeekableChunkProviding {
    let wrapped: SeekableChunkProviding
    let serve: [Int: Int]

    func ciphertextChunk(at index: Int) async throws -> Data {
        try await wrapped.ciphertextChunk(at: serve[index] ?? index)
    }
}

/// Serves the named indices from a different ENC3 file entirely.
struct ForeignChunkProvider: SeekableChunkProviding {
    let local: SeekableChunkProviding
    let foreign: SeekableChunkProviding
    let foreignIndices: Set<Int>

    func ciphertextChunk(at index: Int) async throws -> Data {
        foreignIndices.contains(index)
            ? try await foreign.ciphertextChunk(at: index)
            : try await local.ciphertextChunk(at: index)
    }
}

// MARK: - Async assertion helper

func XCTAssertNoThrowAsync<T>(_ expression: @autoclosure () async throws -> T,
                              _ message: String = "expected no error",
                              file: StaticString = #filePath,
                              line: UInt = #line) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("\(message): \(error)", file: file, line: line)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  _ message: String = "expected an error",
                                  file: StaticString = #filePath,
                                  line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        handler(error)
    }
}
