//
//  SecretFileHandlerV2.swift
//  EncameraCore
//
//  V2 file format handler with embedded encrypted metadata support.
//

import Foundation
import Sodium
import Combine

/// Handler for v2 encrypted files with embedded metadata
///
/// This class provides encryption and decryption for the v2 file format,
/// which includes an encrypted metadata header at the beginning of each file.
///
/// - Important: This handler is **v2-only**. It has NO backwards compatibility with
///   v1 files: `skipMetadataIfV2` consumes the first 4 bytes to test for the v2 magic
///   and, because `FileLikeHandler` cannot seek back, it *throws*
///   `SecretFilesError.decryptError` when those bytes are not the magic.
///   Use it for decryption only when the file is known to be v2 — e.g. one this class
///   just wrote. **For decrypting a file of unknown or mixed provenance, use
///   `SecretFileHandler`**, which sniffs the magic and reads both v1 and v2.
///   (An earlier version of this comment falsely claimed v1 compatibility; that claim
///   caused ENC-135, where migrated v1 media became undecryptable in CloudKit albums.)
public class SecretFileHandlerV2<T: MediaDescribing> {
    
    let sourceMedia: T
    let targetURL: URL?
    let keyBytes: Array<UInt8>
    let sodium = Sodium()
    
    private var progressSubject = PassthroughSubject<Double, Never>()
    private let defaultBlockSize: Int = 20480
    
    /// Publisher for encryption/decryption progress (0.0 to 1.0)
    public var progress: AnyPublisher<Double, Never> {
        progressSubject.eraseToAnyPublisher()
    }
    
    /// Initialize the handler
    /// - Parameters:
    ///   - keyBytes: Encryption key bytes
    ///   - source: Source media to encrypt/decrypt
    ///   - targetURL: Destination URL for the encrypted/decrypted file
    public init(keyBytes: Array<UInt8>, source: T, targetURL: URL? = nil) {
        self.keyBytes = keyBytes
        self.sourceMedia = source
        self.targetURL = targetURL
    }
    
    // MARK: - Encryption with Metadata
    
    /// Encrypt media with v2 format including embedded metadata
    /// - Parameter metadata: Metadata to embed in the encrypted file
    /// - Returns: EncryptedMedia pointing to the new encrypted file
    @discardableResult
    public func encryptWithMetadata(_ metadata: EncryptedFileMetadata) async throws -> EncryptedMedia {
        
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            debugPrint("Could not create stream with key")
            throw SecretFilesError.encryptError
        }
        
        guard let destinationURL = targetURL else {
            throw SecretFilesError.sourceFileAccessError("No destination URL provided")
        }
        
        guard let destinationMedia = EncryptedMedia(source: destinationURL, type: sourceMedia.mediaType) else {
            throw SecretFilesError.sourceFileAccessError("Could not create encrypted media at destination")
        }
        
        do {
            let destinationHandler = try FileLikeHandler(media: destinationMedia, mode: .writing)
            let sourceHandler = try FileLikeHandler(media: sourceMedia, mode: .reading)
            
            try destinationHandler.prepareIfDoesNotExist()
            
            // Build and write v2 header with encrypted metadata
            let metadataHandler = EncryptedMetadataHandler()
            let v2Header = try metadataHandler.buildV2Header(metadata: metadata, keyBytes: keyBytes)
            try destinationHandler.write(contentsOf: v2Header)
            
            // Now write the v1-compatible content format (stream header + blocks)
            let header = streamEnc.header()
            try destinationHandler.write(contentsOf: Data(header))
            
            var writeBlockSizeOperation: (([UInt8]) throws -> Void)?
            writeBlockSizeOperation = { cipherText in
                let cipherTextLength = withUnsafeBytes(of: cipherText.count) {
                    Array($0)
                }
                try destinationHandler.write(contentsOf: Data(cipherTextLength))
                writeBlockSizeOperation = nil
            }
            
            let processor = ChunkedFilesProcessor(sourceFileHandle: sourceHandler, blockSize: defaultBlockSize)
            
            return try await withTaskCancellationHandler {
                for try await (bytes, isFinal) in processor.processFile(progressUpdate: { progress in
                    self.progressSubject.send(progress)
                }) {
                    
                    try Task.checkCancellation()
                    try autoreleasepool {
                        let message = streamEnc.push(message: bytes, tag: isFinal ? .FINAL : .MESSAGE)!
                        try writeBlockSizeOperation?(message)
                        try destinationHandler.write(contentsOf: Data(message))
                    }
                }
                
                guard let media = EncryptedMedia(source: destinationURL) else {
                    throw SecretFilesError.sourceFileAccessError("Could not create media")
                }
                return media
            } onCancel: {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            
        } catch let error as SecretFilesError {
            throw error
        } catch {
            debugPrint("Error encrypting with metadata \(error)")
            throw SecretFilesError.sourceFileAccessError("Could not access source file: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Decryption (V2-aware)
    
    /// Decrypts a file, automatically detecting v1 or v2 format
    /// - Returns: AsyncThrowingStream of decrypted data chunks
    public func decryptFile() async throws -> AsyncThrowingStream<Data, Error> {
        do {
            let fileHandler = try FileLikeHandler(media: sourceMedia, mode: .reading)
            
            // Detect file version and skip metadata if v2
            try await skipMetadataIfV2(fileHandler: fileHandler)
            
            // Now read and decrypt content (same format as v1)
            let headerBytesCount = 24
            guard let headerBytes = try fileHandler.read(upToCount: headerBytesCount) else {
                throw SecretFilesError.decryptError("Could not read header")
            }
            
            var headerBuffer = [UInt8](repeating: 0, count: headerBytesCount)
            headerBytes.copyBytes(to: &headerBuffer, count: headerBytesCount)
            
            guard let blockSizeInfo = try fileHandler.read(upToCount: 8) else {
                throw SecretFilesError.decryptError("Could not read block size")
            }
            let blockSize: UInt32 = blockSizeInfo.withUnsafeBytes { $0.load(as: UInt32.self) }
            
            guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: headerBuffer) else {
                throw SecretFilesError.keyError
            }
            
            let processor = ChunkedFilesProcessor(sourceFileHandle: fileHandler, blockSize: Int(blockSize))
            return AsyncThrowingStream<Data, Error> { continuation in
                
                let readTask = Task {
                    do {
                        for try await (bytes, _) in processor.processFile(progressUpdate: { progress in
                            self.progressSubject.send(progress)
                        }) {
                            
                            try Task.checkCancellation()
                            try autoreleasepool {
                                guard let (message, _) = streamDec.pull(cipherText: bytes) else {
                                    throw SecretFilesError.decryptError("Could not decrypt message")
                                }
                                continuation.yield(Data(message))
                            }
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { termination in
                    switch termination {
                    case .cancelled:
                        readTask.cancel()
                    default:
                        break
                    }
                }
            }
        } catch {
            throw SecretFilesError.decryptError("Could not access source file")
        }
    }
    
    /// Decrypts the file to memory
    /// - Returns: CleartextMedia containing the decrypted data
    public func decryptInMemory() async throws -> CleartextMedia {
        var accumulatedData = Data()
        
        do {
            for try await chunk in try await decryptFile() {
                accumulatedData.append(chunk)
            }
            
            return CleartextMedia(source: accumulatedData, mediaType: sourceMedia.mediaType, id: sourceMedia.id)
        } catch {
            throw SecretFilesError.decryptError("Could not decrypt file")
        }
    }
    
    /// Decrypts the file to a URL
    /// - Returns: CleartextMedia with the decrypted file URL
    public func decryptToURL() async throws -> CleartextMedia {
        guard let destinationURL = targetURL else {
            throw SecretFilesError.sourceFileAccessError("Target URL not set")
        }
        
        let destinationMedia = CleartextMedia(source: destinationURL)
        let destinationHandler = try FileLikeHandler(media: destinationMedia, mode: .writing)
        try destinationHandler.prepareIfDoesNotExist()
        
        return try await withTaskCancellationHandler {
            for try await data in try await decryptFile() {
                try Task.checkCancellation()
                try autoreleasepool {
                    try destinationHandler.write(contentsOf: data)
                }
            }
            try destinationHandler.closeReader()
            
            return CleartextMedia(source: destinationURL)
        } onCancel: {
            try? FileManager.default.removeItem(at: destinationURL)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Skips the metadata section if this is a v2 file
    private func skipMetadataIfV2(fileHandler: FileLikeHandler<T>) async throws {
        // Read first 4 bytes to check for v2 magic
        guard let magicData = try fileHandler.read(upToCount: EncryptedFileFormat.magicSize),
              magicData.count == EncryptedFileFormat.magicSize else {
            // Can't read - might be empty or corrupt, will fail later
            return
        }
        
        if Array(magicData) == EncryptedFileFormat.magic {
            // V2 file - skip the rest of the header
            
            // Read version (2 bytes)
            _ = try fileHandler.read(upToCount: EncryptedFileFormat.versionSize)
            
            // Read flags (2 bytes)
            _ = try fileHandler.read(upToCount: EncryptedFileFormat.flagsSize)
            
            // Read metadata length (4 bytes)
            guard let lengthData = try fileHandler.read(upToCount: EncryptedFileFormat.metadataLengthSize),
                  lengthData.count == EncryptedFileFormat.metadataLengthSize else {
                throw SecretFilesError.decryptError("Invalid v2 file format")
            }
            let metadataLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
            
            // Skip over the encrypted metadata
            _ = try fileHandler.read(upToCount: Int(metadataLength))
            
            // Now positioned at v1-format content
        } else {
            // V1 file. The 4 bytes just consumed are the first 4 of the 24-byte stream
            // header, and `FileLikeHandler` cannot seek back to recover them, so this
            // handler cannot decrypt V1 — by design, not as a temporary limitation.
            // `SecretFileHandler.setupDecryption` handles exactly this case by reading
            // the remaining 20 bytes and reassembling the header; callers that may see
            // either format must use that handler instead.
            throw SecretFilesError.decryptError("V1 file detected - use SecretFileHandler for backwards compatibility")
        }
    }
}
