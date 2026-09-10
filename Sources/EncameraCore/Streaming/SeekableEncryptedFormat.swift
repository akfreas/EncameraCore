//
//  SeekableEncryptedFormat.swift
//  EncameraCore
//
//  ENC3 — the seekable sibling of the ENC2 file format.
//
//  ENC2 encrypts a file as one `crypto_secretstream_xchacha20poly1305` stream.
//  That construction ratchets its state on every push, so block *k* cannot be
//  decrypted without having pulled blocks 0…k-1. It is a perfect fit for
//  "decrypt this whole file once" and a total non-starter for "seek to 4:12",
//  which is why streaming a large video out of CloudKit is impossible on ENC2 no
//  matter how the bytes are transported. See
//  Documentation/chunked-ckasset-video-streaming.md §3.
//
//  ENC3 encrypts each fixed-size plaintext chunk *independently* with
//  `crypto_aead_xchacha20poly1305_ietf`. Random access becomes arithmetic: chunk
//  ciphertexts are a constant size, so a plaintext byte range maps to a chunk
//  index range with no lookup table. This is the STREAM construction (Rogaway et
//  al.) as used by age and Tink's streaming AEAD — the position binding in the
//  AAD is the load-bearing part and is documented on `chunkAAD` below.
//
//  ENC3 is NOT a replacement for ENC2. Photos, Live Photo components and small
//  videos stay on ENC2; only blobs above `SeekableEncryptedFormat.threshold` are
//  written this way, and the format is chosen per-file by magic sniffing exactly
//  as v1/v2 already are.
//

import Foundation
import Sodium

// MARK: - Errors

public enum SeekableFormatError: Error, Equatable {
    /// The bytes do not begin with the ENC3 magic. Callers that may be handed an
    /// ENC2 file must sniff before constructing a reader.
    case notSeekableFormat
    case unsupportedVersion(UInt16)
    case truncatedHeader
    /// A chunk failed to authenticate. Covers a wrong key, a corrupted chunk, and
    /// — because position is bound into the AAD — a reordered or spliced one.
    case chunkAuthenticationFailed(index: Int)
    case metadataAuthenticationFailed
    case encryptionFailed
    /// The provider returned a chunk of the wrong size, so the file has been
    /// truncated or the provider is serving a different file.
    case chunkSizeMismatch(index: Int, expected: Int, got: Int)
    case rangeOutOfBounds
}

// MARK: - Geometry

/// Pure arithmetic over an ENC3 layout: no crypto, no I/O, no allocation.
///
/// Every "which bytes do I need for this seek" question in the streaming stack
/// resolves here, which is why it is a value type with no dependencies — the
/// mapping is the part most worth testing exhaustively, and it can be tested
/// without a key, a file, or a network.
public struct SeekableChunkGeometry: Sendable, Equatable {
    /// Plaintext bytes per chunk (the last chunk may hold fewer).
    public let chunkSize: Int
    /// Total plaintext length of the file.
    public let plaintextLength: Int
    /// Bytes the header occupies before chunk 0 begins.
    public let headerLength: Int

    /// Per-chunk ciphertext overhead: a 24-byte nonce plus the 16-byte Poly1305
    /// tag. swift-sodium exposes no deterministic-nonce encrypt, so rather than
    /// reach past it into Clibsodium to derive a nonce from the chunk index, each
    /// chunk simply carries the random nonce libsodium picked. That costs 24 bytes
    /// per chunk (0.0006% at a 4 MiB chunk), keeps ciphertext chunks a constant
    /// size — which is all the offset arithmetic actually needs — and removes the
    /// class of bug where a counter-derived nonce repeats.
    public static let nonceBytes = 24
    public static let tagBytes = 16
    public static let chunkOverhead = nonceBytes + tagBytes

    public init(chunkSize: Int, plaintextLength: Int, headerLength: Int) {
        self.chunkSize = max(1, chunkSize)
        self.plaintextLength = max(0, plaintextLength)
        self.headerLength = max(0, headerLength)
    }

    /// Number of chunks. A zero-length file has zero chunks, not one empty one.
    public var chunkCount: Int {
        guard plaintextLength > 0 else { return 0 }
        return (plaintextLength + chunkSize - 1) / chunkSize
    }

    /// Plaintext bytes in chunk `index` — `chunkSize` for all but the last.
    public func plaintextSize(ofChunk index: Int) -> Int {
        guard index >= 0, index < chunkCount else { return 0 }
        if index == chunkCount - 1 {
            let remainder = plaintextLength % chunkSize
            return remainder == 0 ? chunkSize : remainder
        }
        return chunkSize
    }

    /// Ciphertext bytes chunk `index` occupies on disk / in its CKAsset.
    public func ciphertextSize(ofChunk index: Int) -> Int {
        guard index >= 0, index < chunkCount else { return 0 }
        return plaintextSize(ofChunk: index) + Self.chunkOverhead
    }

    /// Byte offset of chunk `index` within the ENC3 file. Constant-size chunks make
    /// this a multiplication rather than a table lookup — the whole point of the
    /// format.
    public func ciphertextOffset(ofChunk index: Int) -> Int {
        headerLength + index * (chunkSize + Self.chunkOverhead)
    }

    /// Total on-disk size of the ENC3 file.
    public var totalCiphertextLength: Int {
        guard chunkCount > 0 else { return headerLength }
        return ciphertextOffset(ofChunk: chunkCount - 1) + ciphertextSize(ofChunk: chunkCount - 1)
    }

    /// Plaintext offset at which chunk `index` starts.
    public func plaintextOffset(ofChunk index: Int) -> Int {
        index * chunkSize
    }

    /// The chunk holding plaintext byte `offset`.
    public func chunkIndex(forPlaintextOffset offset: Int) -> Int {
        guard chunkSize > 0 else { return 0 }
        return offset / chunkSize
    }

    /// The chunks needed to serve a plaintext byte range, clamped to the file.
    /// Returns an empty range when the request lies entirely past the end.
    public func chunkRange(forPlaintextRange range: Range<Int>) -> Range<Int> {
        let lower = max(0, range.lowerBound)
        let upper = min(plaintextLength, range.upperBound)
        guard lower < upper, chunkCount > 0 else { return 0..<0 }
        let first = chunkIndex(forPlaintextOffset: lower)
        let last = chunkIndex(forPlaintextOffset: upper - 1)
        return first..<min(chunkCount, last + 1)
    }
}

// MARK: - Header

/// The fixed 76-byte ENC3 preamble plus the encrypted metadata section.
///
/// Byte layout (all integers little-endian):
///
/// ```
///  0   4   magic            "ENC3"
///  4   2   version          3
///  6   2   flags            reserved, zero
///  8   4   chunkSize
/// 12   8   plaintextLength
/// 20   4   chunkCount
/// 24   4   metadataLength   byte count of encryptedMetadata
/// 28  16   fileID           random per-file identity
/// 44  32   mutablePlaintext bytes 44–47 key stamp, 48–75 reserved, zero
/// 76   n   encryptedMetadata
/// ```
///
/// `magic`, `fileID`, `chunkCount` and `plaintextLength` are bound into every
/// chunk's AAD (see `chunkAAD`), so changing them after encryption invalidates
/// the file. `mutablePlaintext` is in no AAD and can be rewritten in place at
/// any time; the key stamp is written there after encryption.
///
/// The header is deliberately small and self-contained: the streaming stack
/// stores it on the *parent* CloudKit record as a plain `Data` field, so a player
/// can learn a video's plaintext length — which it must report to AVFoundation
/// before requesting a single byte — without fetching any payload chunk.
public struct SeekableEncryptedHeader: Sendable, Equatable {
    public static let magic: [UInt8] = Array("ENC3".utf8)
    public static let version: UInt16 = 3
    /// magic(4) + version(2) + flags(2) + chunkSize(4) + plaintextLength(8)
    /// + chunkCount(4) + metadataLength(4) + fileID(16) + mutablePlaintext(32)
    public static let fixedSize = 76
    public static let fileIDBytes = 16
    /// 32 bytes of AAD-excluded mutable plaintext after the fileID.
    /// Bytes 0–3 are the key stamp; the rest is reserved (zeroed).
    public static let mutablePlaintextSize = 32
    public static let keyStampSize = 4

    public let chunkSize: Int
    public let plaintextLength: Int
    public let chunkCount: Int
    /// Random per-file identity, mixed into every chunk's AAD.
    ///
    /// Position binding alone is not enough. Every item in an Encamera album is
    /// encrypted under the *same* album key, so without this two videos that happen
    /// to share a byte length and chunk size would produce chunks that are
    /// interchangeable at the same index — identical AAD, and the nonce travels with
    /// the ciphertext, so the swap would authenticate cleanly. A random file id
    /// makes any cross-file splice fail. (This was caught by
    /// `testChunkSplicedFromAnotherFileFailsToAuthenticate`, which passed against an
    /// earlier version of this header that had no such field.)
    public let fileID: Data
    /// 32-byte AAD-excluded mutable plaintext block. Not bound into any
    /// chunk's AAD, so it can be written after encryption without
    /// invalidating the file. Bytes 0–3 hold the key stamp; 4–31 reserved.
    public var mutablePlaintext: Data
    /// Encrypted `EncryptedFileMetadata` JSON (nonce ‖ ciphertext), or empty.
    public let encryptedMetadata: Data

    public init(chunkSize: Int,
                plaintextLength: Int,
                chunkCount: Int,
                fileID: Data,
                mutablePlaintext: Data = Data(count: mutablePlaintextSize),
                encryptedMetadata: Data) {
        self.chunkSize = chunkSize
        self.plaintextLength = plaintextLength
        self.chunkCount = chunkCount
        self.fileID = fileID
        self.mutablePlaintext = mutablePlaintext
        self.encryptedMetadata = encryptedMetadata
    }

    /// A fresh random file identity.
    public static func newFileID() -> Data {
        var bytes = [UInt8](repeating: 0, count: fileIDBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, fileIDBytes, &bytes)
        return Data(bytes)
    }

    public var headerLength: Int { Self.fixedSize + encryptedMetadata.count }

    public var geometry: SeekableChunkGeometry {
        SeekableChunkGeometry(chunkSize: chunkSize,
                              plaintextLength: plaintextLength,
                              headerLength: headerLength)
    }

    public func encoded() -> Data {
        var out = Data(capacity: headerLength)
        out.append(contentsOf: Self.magic)
        out.appendLE(UInt16(Self.version))
        out.appendLE(UInt16(0))                       // flags, reserved for future use
        out.appendLE(UInt32(chunkSize))
        out.appendLE(UInt64(plaintextLength))
        out.appendLE(UInt32(chunkCount))
        out.appendLE(UInt32(encryptedMetadata.count))
        out.append(fileID)
        var slot = mutablePlaintext
        if slot.count < Self.mutablePlaintextSize {
            slot.append(Data(count: Self.mutablePlaintextSize - slot.count))
        }
        out.append(slot.prefix(Self.mutablePlaintextSize))
        out.append(encryptedMetadata)
        return out
    }

    /// Parses a header from the front of `data`. `data` need only contain the
    /// header — the caller is expected to have read `fixedSize` bytes first, learned
    /// the metadata length, and read the rest.
    public static func decode(_ data: Data) throws -> SeekableEncryptedHeader {
        guard data.count >= fixedSize else { throw SeekableFormatError.truncatedHeader }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic else { throw SeekableFormatError.notSeekableFormat }
        let version: UInt16 = data.readLE(at: 4)
        guard version == Self.version else { throw SeekableFormatError.unsupportedVersion(version) }
        let chunkSize = Int(data.readLE(at: 8) as UInt32)
        let plaintextLength = Int(data.readLE(at: 12) as UInt64)
        let chunkCount = Int(data.readLE(at: 20) as UInt32)
        let metadataLength = Int(data.readLE(at: 24) as UInt32)
        guard chunkSize > 0 else { throw SeekableFormatError.truncatedHeader }
        guard data.count >= fixedSize + metadataLength else { throw SeekableFormatError.truncatedHeader }
        let fileID = data.subdata(in: 28..<(28 + fileIDBytes))
        let mutablePlaintext = data.subdata(in: 44..<(44 + mutablePlaintextSize))
        let metadata = data.subdata(in: fixedSize..<(fixedSize + metadataLength))
        return SeekableEncryptedHeader(chunkSize: chunkSize,
                                       plaintextLength: plaintextLength,
                                       chunkCount: chunkCount,
                                       fileID: fileID,
                                       mutablePlaintext: mutablePlaintext,
                                       encryptedMetadata: metadata)
    }

    /// True when `data` begins with the ENC3 magic. Cheap sniff for call sites that
    /// hold a blob of unknown format — ENC2 files must keep going to
    /// `SecretFileHandler`, which reads both v1 and v2.
    public static func isSeekableFormat(_ data: Data) -> Bool {
        guard data.count >= magic.count else { return false }
        return Array([UInt8](data)[0..<magic.count]) == magic
    }

    public static func isSeekableFormat(fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: magic.count) else { return false }
        return isSeekableFormat(head)
    }

    /// Reads and decodes the header off the front of `fileURL`, returning its raw
    /// bytes alongside so a caller that must forward them verbatim (the CloudKit
    /// `encHeader` field) need not re-encode.
    ///
    /// Two reads, because the metadata section is variable-length: the fixed
    /// preamble states how long it is.
    public static func read(fromFileAt fileURL: URL) throws -> (header: SeekableEncryptedHeader, bytes: Data) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        guard let fixed = try handle.read(upToCount: fixedSize), fixed.count == fixedSize else {
            throw SeekableFormatError.truncatedHeader
        }
        let metadataLength = Int(fixed.readLE(at: 24) as UInt32)
        var headerData = fixed
        if metadataLength > 0 {
            guard let rest = try handle.read(upToCount: metadataLength), rest.count == metadataLength else {
                throw SeekableFormatError.truncatedHeader
            }
            headerData.append(rest)
        }
        return (try decode(headerData), headerData)
    }
}

// MARK: - Format constants + AAD

public enum SeekableEncryptedFormat {
    /// Default plaintext chunk size.
    ///
    /// 4 MiB, not the 1 MB the idea started from. 1 MB is the CloudKit *record*
    /// size limit, which explicitly excludes asset fields and so does not apply
    /// here at all. What does apply is round-trip latency: at a ~0.4s per-fetch
    /// latency, 1 MB chunks fetched serially top out near 2 MB/s, which cannot
    /// sustain 4K HEVC (~6-8 MB/s), while 4 MiB reaches ~5 MB/s serial and
    /// saturates the link at a prefetch depth of 3-4. It also quarters the record
    /// count. See the report §4 for the arithmetic.
    public static let defaultChunkSize = 4 * 1024 * 1024

    /// Blobs at or below this size are not worth chunking: one asset fetch already
    /// beats the per-chunk round trips. 50 MiB per the two-device measurements,
    /// which put the chunked-vs-monolithic crossover at 50-100 MB; revisit with
    /// field telemetry.
    public static let threshold = 50 * 1024 * 1024

    /// Additional authenticated data for chunk `index`.
    ///
    /// This is the security-critical part of the format and the thing ENC2 got for
    /// free. Independently-encrypted chunks each authenticate their own contents,
    /// but nothing stops an attacker who can write storage from reordering them,
    /// dropping the tail, or splicing in a chunk from another file — every
    /// individual chunk would still verify on its own. Four fields close that:
    ///
    /// - `fileID` — rejects a chunk lifted from another file. Necessary because
    ///   every item in an album shares one key, so index and length alone are not
    ///   distinguishing.
    /// - `index` — rejects a reordered chunk.
    /// - `chunkCount` and `plaintextLength` — reject a truncated or extended file,
    ///   including one whose header was rewritten to match.
    static func chunkAAD(fileID: Data, index: Int, chunkCount: Int, plaintextLength: Int) -> [UInt8] {
        var aad = SeekableEncryptedHeader.magic
        aad.append(contentsOf: [UInt8](fileID))
        aad.appendBE(UInt64(index))
        aad.appendBE(UInt64(chunkCount))
        aad.appendBE(UInt64(plaintextLength))
        return aad
    }

    /// AAD for the header's metadata section — domain-separated from chunk AAD so a
    /// chunk can never be substituted for the metadata blob or vice versa.
    static func metadataAAD(fileID: Data, plaintextLength: Int) -> [UInt8] {
        var aad = Array("ENC3META".utf8)
        aad.append(contentsOf: [UInt8](fileID))
        aad.appendBE(UInt64(plaintextLength))
        return aad
    }

    /// JSON encoding for the metadata section. Shares `EncryptedMetadataHandler`'s
    /// coder, so it matches the ENC2/V2 encoding byte-for-byte and both formats'
    /// metadata is interchangeable at the model level.
    public static func encodeMetadata(_ metadata: EncryptedFileMetadata) throws -> Data {
        try EncryptedMetadataHandler.encodeMetadata(metadata)
    }

    public static func decodeMetadata(_ data: Data) throws -> EncryptedFileMetadata {
        try EncryptedMetadataHandler.decodeMetadata(data)
    }
}

// MARK: - Chunk provider

/// Where a reader gets ciphertext chunks from. The local-file and CloudKit
/// implementations are interchangeable, which is what lets the player be tested
/// against a file on disk and then pointed at the network unchanged.
public protocol SeekableChunkProviding: Sendable {
    /// Ciphertext for chunk `index`, including its 24-byte nonce prefix.
    func ciphertextChunk(at index: Int) async throws -> Data
}

/// Serves chunks out of a local ENC3 file.
public struct FileChunkProvider: SeekableChunkProviding {
    private let fileURL: URL
    private let geometry: SeekableChunkGeometry

    public init(fileURL: URL, geometry: SeekableChunkGeometry) {
        self.fileURL = fileURL
        self.geometry = geometry
    }

    public func ciphertextChunk(at index: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(geometry.ciphertextOffset(ofChunk: index)))
        let want = geometry.ciphertextSize(ofChunk: index)
        let data = try handle.read(upToCount: want) ?? Data()
        guard data.count == want else {
            throw SeekableFormatError.chunkSizeMismatch(index: index, expected: want, got: data.count)
        }
        return data
    }
}

// MARK: - Writer

/// Encrypts a plaintext file into ENC3.
public struct SeekableEncryptedWriter {
    private let keyBytes: [UInt8]
    private let chunkSize: Int
    private let sodium = Sodium()

    public init(keyBytes: [UInt8], chunkSize: Int = SeekableEncryptedFormat.defaultChunkSize) {
        self.keyBytes = keyBytes
        self.chunkSize = chunkSize
    }

    /// Encrypts `source` to `destination`, streaming a chunk at a time so a 4 GB
    /// video never costs more than one chunk of resident memory.
    /// - Returns: the header that was written, whose geometry describes the result.
    @discardableResult
    public func encrypt(source: URL,
                        destination: URL,
                        metadata: Data? = nil,
                        progress: ((Double) -> Void)? = nil) throws -> SeekableEncryptedHeader {
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let plaintextLength = (attrs[.size] as? NSNumber)?.intValue ?? 0

        let geometry = SeekableChunkGeometry(chunkSize: chunkSize,
                                             plaintextLength: plaintextLength,
                                             headerLength: 0)
        let chunkCount = geometry.chunkCount
        let fileID = SeekableEncryptedHeader.newFileID()

        let encryptedMetadata: Data
        if let metadata, !metadata.isEmpty {
            let aad = SeekableEncryptedFormat.metadataAAD(fileID: fileID, plaintextLength: plaintextLength)
            guard let sealed: Bytes = sodium.aead.xchacha20poly1305ietf.encrypt(
                message: [UInt8](metadata), secretKey: keyBytes, additionalData: aad
            ) else { throw SeekableFormatError.encryptionFailed }
            encryptedMetadata = Data(sealed)
        } else {
            encryptedMetadata = Data()
        }

        let header = SeekableEncryptedHeader(chunkSize: chunkSize,
                                             plaintextLength: plaintextLength,
                                             chunkCount: chunkCount,
                                             fileID: fileID,
                                             encryptedMetadata: encryptedMetadata)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }

        try writer.write(contentsOf: header.encoded())

        for index in 0..<chunkCount {
            try autoreleasepool {
                let want = header.geometry.plaintextSize(ofChunk: index)
                let plaintext = try reader.read(upToCount: want) ?? Data()
                let aad = SeekableEncryptedFormat.chunkAAD(fileID: fileID,
                                                           index: index,
                                                           chunkCount: chunkCount,
                                                           plaintextLength: plaintextLength)
                guard let sealed: Bytes = sodium.aead.xchacha20poly1305ietf.encrypt(
                    message: [UInt8](plaintext), secretKey: keyBytes, additionalData: aad
                ) else { throw SeekableFormatError.encryptionFailed }
                try writer.write(contentsOf: Data(sealed))
            }
            progress?(Double(index + 1) / Double(max(1, chunkCount)))
        }
        try writer.synchronize()
        return header
    }
}

// MARK: - Reader

/// A tiny LRU of decrypted chunks, owned by one `SeekableEncryptedReader`.
///
/// Two entries: AVFoundation walks a chunk with several small range requests and
/// re-reads after a stall, so the working set is the current chunk and the one it
/// is crossing into. The budget is two chunks of plaintext per reader — 8 MiB at
/// the 4 MiB production chunk size, and the size of the file itself for anything
/// that fits in one chunk.
///
/// A class so reader copies share it, `@unchecked Sendable` behind an `NSLock`
/// because the resource loader serves concurrent loading requests off separate
/// tasks. Only bytes that already passed `decrypt` are ever stored.
private final class PlaintextChunkCache: @unchecked Sendable {
    private static let capacity = 2
    private let lock = NSLock()
    /// Least-recently-used first.
    private var entries: [(index: Int, plaintext: Data)] = []

    func plaintext(at index: Int) -> Data? {
        lock.withLock {
            guard let position = entries.firstIndex(where: { $0.index == index }) else { return nil }
            let entry = entries.remove(at: position)
            entries.append(entry)
            return entry.plaintext
        }
    }

    func store(_ plaintext: Data, at index: Int) {
        lock.withLock {
            entries.removeAll { $0.index == index }
            entries.append((index, plaintext))
            while entries.count > Self.capacity { entries.removeFirst() }
        }
    }
}

/// Random-access decryption. Give it a header and a chunk provider and it will
/// serve any plaintext byte range, fetching only the chunks that range touches.
public struct SeekableEncryptedReader: Sendable {
    private let keyBytes: [UInt8]
    public let header: SeekableEncryptedHeader
    private let provider: SeekableChunkProviding
    /// Decrypted chunks, so the several small range requests AVFoundation issues
    /// over one chunk cost one AEAD open between them. Created here and never
    /// injected, so its entries can only ever be served back to the key and header
    /// this reader was built with.
    private let plaintextCache = PlaintextChunkCache()
    /// Computed, not stored: `Sodium` is not `Sendable`, and this reader is handed
    /// across concurrency domains by the resource loader. Construction is just
    /// struct initialization — libsodium itself is initialized once, globally.
    private var sodium: Sodium { Sodium() }

    public var geometry: SeekableChunkGeometry { header.geometry }

    public init(keyBytes: [UInt8], header: SeekableEncryptedHeader, provider: SeekableChunkProviding) {
        self.keyBytes = keyBytes
        self.header = header
        self.provider = provider
    }

    /// Reads the ENC3 header off a local file and returns a reader over it.
    public static func forFile(_ url: URL, keyBytes: [UInt8]) throws -> SeekableEncryptedReader {
        let (header, _) = try SeekableEncryptedHeader.read(fromFileAt: url)
        return SeekableEncryptedReader(keyBytes: keyBytes,
                                       header: header,
                                       provider: FileChunkProvider(fileURL: url, geometry: header.geometry))
    }

    /// Decrypts one chunk, or returns it from the plaintext cache.
    public func plaintextChunk(at index: Int) async throws -> Data {
        let geo = geometry
        guard index >= 0, index < geo.chunkCount else { throw SeekableFormatError.rangeOutOfBounds }
        if let cached = plaintextCache.plaintext(at: index) { return cached }
        let ciphertext = try await provider.ciphertextChunk(at: index)
        let expected = geo.ciphertextSize(ofChunk: index)
        guard ciphertext.count == expected else {
            throw SeekableFormatError.chunkSizeMismatch(index: index, expected: expected, got: ciphertext.count)
        }
        let aad = SeekableEncryptedFormat.chunkAAD(fileID: header.fileID,
                                                   index: index,
                                                   chunkCount: geo.chunkCount,
                                                   plaintextLength: geo.plaintextLength)
        let plain = sodium.aead.xchacha20poly1305ietf.decrypt(
            nonceAndAuthenticatedCipherText: Bytes(ciphertext),
            secretKey: keyBytes,
            additionalData: aad
        )
        guard let plain else {
            throw SeekableFormatError.chunkAuthenticationFailed(index: index)
        }
        let plaintext = Data(plain)
        plaintextCache.store(plaintext, at: index)
        return plaintext
    }

    /// Decrypts exactly the plaintext bytes in `range`, fetching only the chunks it
    /// overlaps. This is the call the AVFoundation resource loader makes, and the
    /// reason a seek costs one chunk instead of the whole file.
    public func plaintext(range: Range<Int>) async throws -> Data {
        let geo = geometry
        let clampedLower = max(0, range.lowerBound)
        let clampedUpper = min(geo.plaintextLength, range.upperBound)
        guard clampedLower < clampedUpper else { return Data() }

        var out = Data(capacity: clampedUpper - clampedLower)
        for index in geo.chunkRange(forPlaintextRange: clampedLower..<clampedUpper) {
            let chunkStart = geo.plaintextOffset(ofChunk: index)
            let plain = try await plaintextChunk(at: index)
            let sliceLower = max(0, clampedLower - chunkStart)
            let sliceUpper = min(plain.count, clampedUpper - chunkStart)
            guard sliceLower < sliceUpper else { continue }
            out.append(plain[(plain.startIndex + sliceLower)..<(plain.startIndex + sliceUpper)])
        }
        return out
    }

    /// Decrypts the metadata section, if the file carries one.
    public func metadata() throws -> Data? {
        guard !header.encryptedMetadata.isEmpty else { return nil }
        let aad = SeekableEncryptedFormat.metadataAAD(fileID: header.fileID,
                                                      plaintextLength: header.plaintextLength)
        guard let plain = sodium.aead.xchacha20poly1305ietf.decrypt(
            nonceAndAuthenticatedCipherText: [UInt8](header.encryptedMetadata),
            secretKey: keyBytes,
            additionalData: aad
        ) else {
            throw SeekableFormatError.metadataAuthenticationFailed
        }
        return Data(plain)
    }

    /// Whole-file decrypt to `destination`, chunk by chunk. The compatibility path:
    /// anything that still wants a plaintext file on disk (export, share sheet)
    /// keeps working against an ENC3 blob.
    public func decryptToFile(destination: URL, progress: ((Double) -> Void)? = nil) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let count = geometry.chunkCount
        for index in 0..<count {
            let plain = try await plaintextChunk(at: index)
            try handle.write(contentsOf: plain)
            progress?(Double(index + 1) / Double(max(1, count)))
        }
        try handle.synchronize()
    }
}

// MARK: - Little/big-endian helpers

// `withUnsafeBytes` is qualified with `Swift.` throughout: inside a `Data` (or
// `Array`) extension the bare name resolves to the collection's own instance
// method, not the global `withUnsafeBytes(of:_:)` these need.
extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        let le = value.littleEndian
        Swift.withUnsafeBytes(of: le) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        precondition(offset + size <= count, "readLE out of bounds")
        let slice = self[(startIndex + offset)..<(startIndex + offset + size)]
        var value: T = 0
        for (shift, byte) in slice.enumerated() {
            value |= T(truncatingIfNeeded: Int(byte)) << (8 * shift)
        }
        return value
    }
}

extension Array where Element == UInt8 {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        let be = value.bigEndian
        Swift.withUnsafeBytes(of: be) { append(contentsOf: $0) }
    }
}
