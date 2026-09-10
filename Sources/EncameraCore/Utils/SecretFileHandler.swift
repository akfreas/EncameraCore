//
//  SecretFilesManager.swift
//  Encamera
//
//  Created by Alexander Freas on 28.04.22.
//

import Foundation
import Sodium
import Combine


public enum SecretFilesError: ErrorDescribable {
    case keyError
    case encryptError
    case decryptError(String)
    case sourceFileAccessError(String)
    case destinationFileAccessError
    case createThumbnailError
    case createVideoThumbnailError
    case fileTypeError
    case createPreviewError
    case iCloudFileNotAvailable

    public var displayDescription: String {
        switch self {
        case .keyError:
            return "An error occurred with the encryption key."
        case .encryptError:
            return "Failed to encrypt the file."
        case .decryptError(let message):
            return "Failed to decrypt the file. \(message)"
        case .sourceFileAccessError(let filePath):
            return "Unable to access the source file at path: \(filePath)."
        case .destinationFileAccessError:
            return "Unable to access the destination file."
        case .createThumbnailError:
            return "Failed to create a thumbnail for the file."
        case .createVideoThumbnailError:
            return "Failed to create a video thumbnail."
        case .fileTypeError:
            return "The file type is not supported."
        case .createPreviewError:
            return "Failed to create a preview for the file."
        case .iCloudFileNotAvailable:
            let monitor = NetworkMonitor.shared
            if !monitor.isConnected {
                return L10n.ICloudError.notAvailableNoConnection
            } else if monitor.isOnCellular {
                return L10n.ICloudError.notAvailableCellular
            } else {
                return L10n.ICloudError.notAvailableWiFi
            }
        }
    }
}


protocol SecretFileHandling {

    associatedtype SourceMediaType: MediaDescribing

    var progress: AnyPublisher<Double, Never> { get }
    var sourceMedia: SourceMediaType { get }
    var keyBytes: Array<UInt8> { get }
    var sodium: Sodium { get }
    func encrypt() async throws -> EncryptedMedia
    func decryptToURL() async throws -> CleartextMedia
    func decryptInMemory() async throws -> CleartextMedia

}

private protocol SecretFileHandlerInt: SecretFileHandling {
    var progressSubject: PassthroughSubject<Double, Never> { get }
}

/// Result of checking for V2 format and reading the appropriate header
private struct DecryptionSetup {
    let streamHeader: [UInt8]
    let blockSize: UInt32
    let isV2: Bool
}

extension SecretFileHandlerInt {

    var progress: AnyPublisher<Double, Never> {
        progressSubject.eraseToAnyPublisher()
    }

    var sodium: Sodium {
        Sodium()
    }
    
    /// Checks whether the source media's underlying file is available on disk.
    /// Returns `true` when the file is a URL-backed iCloud item that hasn't been downloaded yet.
    private func isSourceFileUnavailableFromICloud() -> Bool {
        guard case .url(let sourceURL) = sourceMedia.source else {
            return false
        }
        return iCloudFileStatusUtil.needsDownload(url: sourceURL)
    }

    /// Checks for V2 format and reads the stream header appropriately
    /// Returns the stream header bytes and block size, ready for decryption
    private func setupDecryption<M: MediaDescribing>(fileHandler: FileLikeHandler<M>) throws -> DecryptionSetup {
        debugPrint("SecretFileHandler: Setting up decryption")
        
        // Read first 4 bytes to check for V2 magic
        guard let magicData = try fileHandler.read(upToCount: EncryptedFileFormat.magicSize),
              magicData.count == EncryptedFileFormat.magicSize else {
            if isSourceFileUnavailableFromICloud() {
                throw SecretFilesError.iCloudFileNotAvailable
            }
            throw SecretFilesError.decryptError("Could not read file header")
        }
        
        let magicBytes = Array(magicData)
        debugPrint("SecretFileHandler: First 4 bytes: \(magicBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        if magicBytes == EncryptedFileFormat.magic {
            debugPrint("SecretFileHandler: V2 file detected, skipping metadata header")
            
            // V2 file - read and skip the rest of the metadata header
            // Read version (2 bytes)
            guard let versionData = try fileHandler.read(upToCount: EncryptedFileFormat.versionSize),
                  versionData.count == EncryptedFileFormat.versionSize else {
                throw SecretFilesError.decryptError("Could not read V2 version")
            }
            
            // Read flags (2 bytes)
            guard let flagsData = try fileHandler.read(upToCount: EncryptedFileFormat.flagsSize),
                  flagsData.count == EncryptedFileFormat.flagsSize else {
                throw SecretFilesError.decryptError("Could not read V2 flags")
            }
            
            // Read metadata length (4 bytes)
            guard let lengthData = try fileHandler.read(upToCount: EncryptedFileFormat.metadataLengthSize),
                  lengthData.count == EncryptedFileFormat.metadataLengthSize else {
                throw SecretFilesError.decryptError("Could not read V2 metadata length")
            }
            let metadataLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
            debugPrint("SecretFileHandler: V2 metadata length: \(metadataLength) bytes")
            
            // Validate metadata length to prevent excessive memory allocation from malicious files
            guard metadataLength <= EncryptedFileFormat.maxMetadataSize else {
                throw SecretFilesError.decryptError("Invalid metadata length: \(metadataLength) exceeds maximum allowed size")
            }
            
            // Skip over the encrypted metadata
            guard let metadataData = try fileHandler.read(upToCount: Int(metadataLength)),
                  metadataData.count == Int(metadataLength) else {
                throw SecretFilesError.decryptError("Could not skip V2 metadata")
            }
            
            debugPrint("SecretFileHandler: V2 metadata skipped, reading stream header")
            
            // Now read the 24-byte stream header
            guard let headerData = try fileHandler.read(upToCount: 24),
                  headerData.count == 24 else {
                throw SecretFilesError.decryptError("Could not read stream header after V2 metadata")
            }
            var headerBuffer = [UInt8](repeating: 0, count: 24)
            headerData.copyBytes(to: &headerBuffer, count: 24)
            
            // Read block size (8 bytes, but we only use first 4)
            guard let blockSizeData = try fileHandler.read(upToCount: 8),
                  blockSizeData.count == 8 else {
                throw SecretFilesError.decryptError("Could not read block size")
            }
            let blockSize: UInt32 = blockSizeData.withUnsafeBytes { $0.load(as: UInt32.self) }
            debugPrint("SecretFileHandler: V2 block size: \(blockSize)")
            
            return DecryptionSetup(streamHeader: headerBuffer, blockSize: blockSize, isV2: true)
            
        } else {
            debugPrint("SecretFileHandler: V1 file detected")
            
            // V1 file - the 4 bytes we read are the first 4 bytes of the 24-byte stream header
            // Read the remaining 20 bytes
            guard let remainingHeaderData = try fileHandler.read(upToCount: 20),
                  remainingHeaderData.count == 20 else {
                throw SecretFilesError.decryptError("Could not read remaining V1 header bytes")
            }
            
            // Combine the 4 bytes we already read with the 20 we just read
            var headerBuffer = [UInt8](repeating: 0, count: 24)
            for (i, byte) in magicBytes.enumerated() {
                headerBuffer[i] = byte
            }
            remainingHeaderData.copyBytes(to: &headerBuffer[4], count: 20)
            
            debugPrint("SecretFileHandler: V1 header reconstructed")
            
            // Read block size (8 bytes, but we only use first 4)
            guard let blockSizeData = try fileHandler.read(upToCount: 8),
                  blockSizeData.count == 8 else {
                throw SecretFilesError.decryptError("Could not read V1 block size")
            }
            let blockSize: UInt32 = blockSizeData.withUnsafeBytes { $0.load(as: UInt32.self) }
            debugPrint("SecretFileHandler: V1 block size: \(blockSize)")
            
            return DecryptionSetup(streamHeader: headerBuffer, blockSize: blockSize, isV2: false)
        }
    }

    /// Streams an ENC3 file's plaintext, chunk by chunk. The seekable format is
    /// per-chunk AEAD — nothing the secretstream machinery below can read — so it
    /// gets its own path; the sniff in `decryptFile` routes here.
    private func seekableDecryptStream(url: URL) throws -> AsyncThrowingStream<Data, Error> {
        let reader = try SeekableEncryptedReader.forFile(url, keyBytes: keyBytes)
        let progressSubject = self.progressSubject
        return AsyncThrowingStream { continuation in
            let readTask = Task {
                do {
                    let count = reader.geometry.chunkCount
                    for index in 0..<count {
                        try Task.checkCancellation()
                        let plain = try await reader.plaintextChunk(at: index)
                        continuation.yield(plain)
                        progressSubject.send(Double(index + 1) / Double(max(1, count)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { readTask.cancel() }
            }
        }
    }

    func decryptFile() async throws -> AsyncThrowingStream<Data, Error> {
        do {
            // Sniff the magic, never assume from context (the ENC-135 lesson):
            // an album can hold V1, V2 and ENC3 files side by side, and this
            // handler is the one place every load path funnels through.
            if case .url(let sourceURL) = sourceMedia.source,
               SeekableEncryptedHeader.isSeekableFormat(fileURL: sourceURL) {
                return try seekableDecryptStream(url: sourceURL)
            }

            let fileHandler: FileLikeHandler<SourceMediaType>
            do {
                fileHandler = try FileLikeHandler(media: sourceMedia, mode: .reading)
            } catch {
                if isSourceFileUnavailableFromICloud() {
                    throw SecretFilesError.iCloudFileNotAvailable
                }
                throw error
            }
            
            // Setup decryption - handles both V1 and V2 formats
            let setup = try setupDecryption(fileHandler: fileHandler)
            debugPrint("SecretFileHandler: Decryption setup complete, isV2: \(setup.isV2), blockSize: \(setup.blockSize)")

            guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: setup.streamHeader) else {
                debugPrint("SecretFileHandler: Failed to init stream pull - key error")
                throw SecretFilesError.keyError
            }

            let processor = ChunkedFilesProcessor(sourceFileHandle: fileHandler, blockSize: Int(setup.blockSize))
            return AsyncThrowingStream<Data, Error> { continuation in

                let readTask = Task {
                    do {
                        for try await (bytes, _) in processor.processFile(progressUpdate: { progress in
                            progressSubject.send(progress)
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
        } catch let error as SecretFilesError {
            throw error
        } catch {
            throw SecretFilesError.decryptError("Could not access source file: \(error)")
        }
    }



}

class SecretFileHandler<T: MediaDescribing>: SecretFileHandlerInt {


    let sourceMedia: T
    let targetURL: URL?
    let keyBytes: Array<UInt8>
    fileprivate var progressSubject = PassthroughSubject<Double, Never>()

    init(keyBytes: Array<UInt8>, source: T, targetURL: URL? = nil) {
        self.keyBytes = keyBytes
        self.sourceMedia = source
        self.targetURL = targetURL
    }

    var cancellables = Set<AnyCancellable>()

    private let defaultBlockSize: Int = 20480

    @discardableResult func encrypt() async throws -> EncryptedMedia {

        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            debugPrint("Could not create stream with key")
            throw SecretFilesError.encryptError
        }
        guard let destinationURL = targetURL else {
            throw SecretFilesError.sourceFileAccessError("No destination URL provided")
        }
        guard let destinationMedia = EncryptedMedia(source: destinationURL, type: .video) else {
            throw SecretFilesError.sourceFileAccessError("Could not create encrypted media at destination")
        }
        do {
            let destinationHandler = try FileLikeHandler(media: destinationMedia, mode: .writing)
            let sourceHandler = try FileLikeHandler(media: sourceMedia, mode: .reading)

            try destinationHandler.prepareIfDoesNotExist()
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

        } catch {
            debugPrint("Error encrypting \(error)")
            throw SecretFilesError.sourceFileAccessError("Could not access source file")
        }
    }


    public func decryptInMemory() async throws -> CleartextMedia {

        var accumulatedData = Data()

        do {
            for try await chunk in try await decryptFile() {
                accumulatedData.append(chunk)
            }

            return CleartextMedia(source: accumulatedData, mediaType: self.sourceMedia.mediaType, id: self.sourceMedia.id)
        } catch let error as SecretFilesError {
            throw error
        } catch {
            throw SecretFilesError.decryptError("Could not decrypt file")
        }


    }


    public func decryptToURL() async throws -> CleartextMedia {
        guard let destinationURL = self.targetURL else {
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
            do {
                try FileManager.default.removeItem(at: destinationURL)
            } catch {
                print("Could not remove item", error)
            }
        }
    }
}
