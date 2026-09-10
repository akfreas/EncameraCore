//
//  EncryptedMetadataHandler.swift
//  EncameraCore
//
//  Created for encrypted file metadata storage feature.
//

import Foundation
import Sodium

/// Handles reading and writing encrypted metadata from/to encrypted files
public actor EncryptedMetadataHandler: DebugPrintable {

    private let sodium = Sodium()
    
    public init() {}

    // MARK: - Metadata JSON Coding

    /// The one place the `EncryptedFileMetadata` JSON coding is configured. Both the
    /// v2 metadata section and the ENC3 header encode through here, which is what
    /// keeps their bytes identical.
    public static func encodeMetadata(_ metadata: EncryptedFileMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys // Deterministic output
        return try encoder.encode(metadata)
    }

    public static func decodeMetadata(_ data: Data) throws -> EncryptedFileMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EncryptedFileMetadata.self, from: data)
    }

    // MARK: - Version Detection
    
    /// Detects whether a file uses v1 (no metadata) or v2 (with metadata) format
    /// - Parameter url: URL to the encrypted file
    /// - Returns: File format version (1 or 2)
    public nonisolated func detectFileVersion(from url: URL) throws -> Int {
        printDebug("detectFileVersion: Checking file at \(url.lastPathComponent)")
        
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        
        guard let magicData = try fileHandle.read(upToCount: EncryptedFileFormat.magicSize),
              magicData.count == EncryptedFileFormat.magicSize else {
            printDebug("detectFileVersion: Could not read magic bytes, assuming v1")
            return 1 // Can't read magic, assume v1
        }
        
        let magicBytes = Array(magicData)
        printDebug("detectFileVersion: Magic bytes: \(magicBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        printDebug("detectFileVersion: Expected v2 magic: \(EncryptedFileFormat.magic.map { String(format: "%02X", $0) }.joined(separator: " "))")

        if magicBytes == EncryptedFileFormat.magic {
            printDebug("detectFileVersion: Detected v2 format")
            return 2
        }

        if magicBytes == SeekableEncryptedHeader.magic {
            printDebug("detectFileVersion: Detected ENC3 (seekable) format")
            return 3
        }

        printDebug("detectFileVersion: Detected v1 format (magic doesn't match)")
        return 1
    }
    
    // MARK: - Reading Metadata
    
    /// Reads only the metadata from an encrypted file without decrypting content
    /// - Parameters:
    ///   - url: URL to the encrypted file
    ///   - keyBytes: Encryption key bytes
    /// - Returns: Decrypted metadata, or nil if v1 file
    public func readMetadata(
        from url: URL,
        keyBytes: [UInt8]
    ) async throws -> EncryptedFileMetadata? {
        printDebug("readMetadata: Starting for file \(url.lastPathComponent)")
        
        if iCloudFileStatusUtil.needsDownload(url: url) {
            printDebug("readMetadata: File needs iCloud download, skipping \(url.lastPathComponent)")
            return nil
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            printDebug("readMetadata: File not found at \(url.path)")
            throw EncryptedMetadataError.fileNotFound
        }
        
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        
        // Step 1: Check for v2 magic
        guard let magicData = try fileHandle.read(upToCount: EncryptedFileFormat.magicSize),
              magicData.count == EncryptedFileFormat.magicSize else {
            printDebug("readMetadata: Could not read magic bytes")
            return nil
        }
        
        let magicBytes = Array(magicData)
        printDebug("readMetadata: Magic bytes: \(magicBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // ENC3: the metadata section lives in the seekable header, AEAD-sealed
        // with its own domain-separated AAD. Same JSON model either way.
        if magicBytes == SeekableEncryptedHeader.magic {
            let reader = try SeekableEncryptedReader.forFile(url, keyBytes: keyBytes)
            guard let plain = try reader.metadata() else {
                printDebug("readMetadata: ENC3 file carries no metadata section")
                return nil
            }
            return try SeekableEncryptedFormat.decodeMetadata(plain)
        }

        guard magicBytes == EncryptedFileFormat.magic else {
            printDebug("readMetadata: v1 file - no metadata (magic doesn't match)")
            return nil
        }
        
        printDebug("readMetadata: v2 file detected, reading metadata")
        
        // Step 2: Read version (2 bytes, little-endian)
        guard let versionData = try fileHandle.read(upToCount: EncryptedFileFormat.versionSize),
              versionData.count == EncryptedFileFormat.versionSize else {
            printDebug("readMetadata: Could not read version")
            throw EncryptedMetadataError.invalidFormat
        }
        let version = versionData.withUnsafeBytes { $0.load(as: UInt16.self) }
        printDebug("readMetadata: File version: \(version)")
        
        guard version >= 2 else {
            printDebug("readMetadata: Unsupported version \(version)")
            throw EncryptedMetadataError.unsupportedVersion(version)
        }
        
        // Step 3: Read flags (2 bytes, reserved - skip)
        guard let flagsData = try fileHandle.read(upToCount: EncryptedFileFormat.flagsSize),
              flagsData.count == EncryptedFileFormat.flagsSize else {
            printDebug("readMetadata: Could not read flags")
            throw EncryptedMetadataError.invalidFormat
        }
        printDebug("readMetadata: Flags bytes read: \(flagsData.count)")
        
        // Step 4: Read metadata section length (4 bytes, little-endian)
        guard let lengthData = try fileHandle.read(upToCount: EncryptedFileFormat.metadataLengthSize),
              lengthData.count == EncryptedFileFormat.metadataLengthSize else {
            printDebug("readMetadata: Could not read metadata length")
            throw EncryptedMetadataError.invalidFormat
        }
        let metadataLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
        printDebug("readMetadata: Metadata length: \(metadataLength) bytes")
        
        guard metadataLength > 0, metadataLength <= EncryptedFileFormat.maxMetadataSize else {
            printDebug("readMetadata: Invalid metadata size: \(metadataLength)")
            throw EncryptedMetadataError.invalidMetadataSize(metadataLength)
        }
        
        // Step 5: Read encrypted metadata (stream header + ciphertext)
        guard let encryptedData = try fileHandle.read(upToCount: Int(metadataLength)),
              encryptedData.count == Int(metadataLength) else {
            printDebug("readMetadata: Could not read encrypted metadata")
            throw EncryptedMetadataError.readError
        }
        printDebug("readMetadata: Read \(encryptedData.count) bytes of encrypted metadata")
        
        // Step 6: Decrypt metadata
        let headerSize = EncryptedFileFormat.streamHeaderSize
        guard encryptedData.count > headerSize else {
            printDebug("readMetadata: Encrypted data too small (size: \(encryptedData.count), header size: \(headerSize))")
            throw EncryptedMetadataError.invalidFormat
        }
        
        let header = Array(encryptedData.prefix(headerSize))
        let cipherText = Array(encryptedData.dropFirst(headerSize))
        printDebug("readMetadata: Stream header size: \(header.count), ciphertext size: \(cipherText.count)")
        
        guard let streamPull = sodium.secretStream.xchacha20poly1305.initPull(
            secretKey: keyBytes,
            header: header
        ) else {
            printDebug("readMetadata: Failed to init stream pull")
            throw EncryptedMetadataError.decryptionFailed
        }
        
        guard let (decryptedBytes, _) = streamPull.pull(cipherText: cipherText) else {
            printDebug("readMetadata: Failed to decrypt metadata ciphertext")
            throw EncryptedMetadataError.decryptionFailed
        }
        printDebug("readMetadata: Decrypted \(decryptedBytes.count) bytes of metadata")
        
        // Step 7: Parse JSON
        do {
            let metadata = try Self.decodeMetadata(Data(decryptedBytes))
            printDebug("readMetadata: Successfully parsed metadata, captureDate: \(String(describing: metadata.captureDate))")
            return metadata
        } catch {
            printDebug("readMetadata: JSON decode error: \(error)")
            throw error
        }
    }
    
    /// Batch read metadata from multiple files (optimized for performance)
    /// - Parameters:
    ///   - urls: Array of file URLs to read
    ///   - keyBytes: Encryption key bytes
    ///   - concurrency: Maximum number of concurrent reads (default: 10)
    ///   - onProgress: Optional callback reporting `(completed, total)` as files
    ///     finish. Throttled to roughly 100 invocations so callers can drive a
    ///     progress bar without flooding the main actor.
    /// - Returns: Array of tuples containing URL and optional metadata
    public func readMetadataBatch(
        from urls: [URL],
        keyBytes: [UInt8],
        concurrency: Int = 10,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async -> [(URL, EncryptedFileMetadata?)] {

        let total = urls.count
        let reportInterval = max(1, total / 100)

        return await withTaskGroup(of: (URL, EncryptedFileMetadata?).self) { group in
            var results: [(URL, EncryptedFileMetadata?)] = []
            results.reserveCapacity(total)

            var pending = urls.makeIterator()
            var inFlight = 0

            // Start initial batch
            while inFlight < concurrency, let url = pending.next() {
                group.addTask { [self] in
                    let metadata = try? await self.readMetadata(from: url, keyBytes: keyBytes)
                    return (url, metadata)
                }
                inFlight += 1
            }

            // Process results and add more tasks
            for await result in group {
                results.append(result)
                inFlight -= 1

                let completed = results.count
                if completed % reportInterval == 0 || completed == total {
                    await onProgress?(completed, total)
                }

                if let url = pending.next() {
                    group.addTask { [self] in
                        let metadata = try? await self.readMetadata(from: url, keyBytes: keyBytes)
                        return (url, metadata)
                    }
                    inFlight += 1
                }
            }

            return results
        }
    }
    
    // MARK: - Writing Metadata
    
    /// Encrypts metadata and returns the complete encrypted metadata section
    /// - Parameters:
    ///   - metadata: Metadata to encrypt
    ///   - keyBytes: Encryption key bytes
    /// - Returns: Encrypted metadata data (stream header + ciphertext)
    public nonisolated func encryptMetadata(
        _ metadata: EncryptedFileMetadata,
        keyBytes: [UInt8]
    ) throws -> Data {
        printDebug("encryptMetadata: Starting metadata encryption")
        let sodium = Sodium()
        
        // Encode to JSON
        let jsonData = try Self.encodeMetadata(metadata)
        printDebug("encryptMetadata: JSON encoded, size: \(jsonData.count) bytes")
        
        // Create encryption stream
        guard let streamPush = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            printDebug("encryptMetadata: Failed to init stream push")
            throw EncryptedMetadataError.encryptionFailed
        }
        
        // Encrypt as single sealed message with FINAL tag
        let header = streamPush.header()
        guard let cipherText = streamPush.push(message: Array(jsonData), tag: .FINAL) else {
            printDebug("encryptMetadata: Failed to encrypt metadata")
            throw EncryptedMetadataError.encryptionFailed
        }
        printDebug("encryptMetadata: Encrypted metadata, header: \(header.count) bytes, ciphertext: \(cipherText.count) bytes")
        
        // Build complete encrypted metadata section
        var result = Data()
        result.reserveCapacity(header.count + cipherText.count)
        result.append(contentsOf: header)
        result.append(contentsOf: cipherText)
        
        printDebug("encryptMetadata: Total encrypted metadata section: \(result.count) bytes")
        return result
    }
    
    /// Builds the complete v2 file header including encrypted metadata
    /// - Parameters:
    ///   - metadata: Metadata to include
    ///   - keyBytes: Encryption key bytes
    /// - Returns: Complete v2 header data ready to be written to file
    public nonisolated func buildV2Header(
        metadata: EncryptedFileMetadata,
        keyBytes: [UInt8]
    ) throws -> Data {
        printDebug("buildV2Header: Building v2 header with metadata")
        
        let encryptedMetadata = try encryptMetadata(metadata, keyBytes: keyBytes)
        
        var header = Data()
        header.reserveCapacity(EncryptedFileFormat.fixedHeaderSize + encryptedMetadata.count - EncryptedFileFormat.streamHeaderSize)
        
        // Magic number "ENC2"
        header.append(contentsOf: EncryptedFileFormat.magic)
        printDebug("buildV2Header: Added magic bytes: \(EncryptedFileFormat.magic.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Version (little-endian)
        var version = EncryptedFileFormat.version
        withUnsafeBytes(of: &version) { header.append(contentsOf: $0) }
        printDebug("buildV2Header: Added version: \(version)")
        
        // Flags (reserved, set to 0)
        var flags: UInt16 = 0
        withUnsafeBytes(of: &flags) { header.append(contentsOf: $0) }
        
        // Metadata section length (little-endian)
        var length = UInt32(encryptedMetadata.count)
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        printDebug("buildV2Header: Metadata section length: \(length) bytes")
        
        // Encrypted metadata (header + ciphertext)
        header.append(encryptedMetadata)
        
        printDebug("buildV2Header: Total v2 header size: \(header.count) bytes")
        return header
    }
    
    // MARK: - Content Offset
    
    /// Returns the byte offset where the actual encrypted content starts
    /// For v1 files, this is 0. For v2 files, it's after the metadata section.
    /// - Parameter url: URL to the encrypted file
    /// - Returns: Byte offset to start reading encrypted content
    public nonisolated func contentOffset(for url: URL) throws -> UInt64 {
        let version = try detectFileVersion(from: url)

        if version == 1 {
            return 0
        }

        if version == 3 {
            // ENC3: chunk 0 begins right after the seekable header.
            let header = try SeekableEncryptedHeader.read(fromFileAt: url).header
            return UInt64(header.headerLength)
        }

        // v2: Read metadata length to calculate offset
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        
        // Seek to metadata length field
        try fileHandle.seek(toOffset: UInt64(EncryptedFileFormat.metadataLengthOffset))
        
        guard let lengthData = try fileHandle.read(upToCount: EncryptedFileFormat.metadataLengthSize),
              lengthData.count == EncryptedFileFormat.metadataLengthSize else {
            throw EncryptedMetadataError.invalidFormat
        }
        
        let metadataLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
        // Offset = fixed header (without stream header) + metadata section
        // = magic(4) + version(2) + flags(2) + length(4) + metadataLength
        return UInt64(EncryptedFileFormat.metadataLengthOffset + EncryptedFileFormat.metadataLengthSize) + UInt64(metadataLength)
    }
}

// MARK: - Convenience Extensions

extension EncryptedMetadataHandler {
    
    /// Checks if a file has embedded metadata (the v2 or ENC3 format)
    public nonisolated func hasEmbeddedMetadata(at url: URL) -> Bool {
        let version = (try? detectFileVersion(from: url)) ?? 1
        return version >= 2
    }
    
    /// Updates metadata in an existing v2 file
    /// Note: This requires rewriting the entire file and should be used sparingly
    public func updateMetadata(
        in url: URL,
        keyBytes: [UInt8],
        update: (inout EncryptedFileMetadata) -> Void
    ) async throws {
        let fileVersion = try detectFileVersion(from: url)
        guard fileVersion == 2 else {
            if fileVersion == 1 {
                throw EncryptedMetadataError.v1FileNoMetadata
            }
            throw EncryptedMetadataError.unsupportedVersion(UInt16(fileVersion))
        }

        guard var metadata = try await readMetadata(from: url, keyBytes: keyBytes) else {
            throw EncryptedMetadataError.v1FileNoMetadata
        }
        
        // Apply the update
        update(&metadata)
        
        // Read the original content portion
        let contentStart = try contentOffset(for: url)
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        
        try fileHandle.seek(toOffset: contentStart)
        guard let contentData = try fileHandle.readToEnd() else {
            throw EncryptedMetadataError.readError
        }
        
        // Build new header
        let newHeader = try buildV2Header(metadata: metadata, keyBytes: keyBytes)
        
        // Write to temp file then replace
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        
        var newFileData = Data()
        newFileData.append(newHeader)
        newFileData.append(contentData)
        
        try newFileData.write(to: tempURL)
        
        // Replace original with updated file
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}
