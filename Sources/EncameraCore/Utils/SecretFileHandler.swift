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

extension SecretFileHandlerInt {

    var progress: AnyPublisher<Double, Never> {
        progressSubject.eraseToAnyPublisher()
    }

    var sodium: Sodium {
        Sodium()
    }


    func decryptFile() async throws -> AsyncThrowingStream<Data, Error> {
        do {
            let fileHandler = try FileLikeHandler(media: sourceMedia, mode: .reading)
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
                        for try await bytes in processor.processFile(progressUpdate: { progress in
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
        } catch {
            throw SecretFilesError.decryptError("Could not access source file")
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
        guard let destinationURL = targetURL,
              let destinationMedia = EncryptedMedia(source: destinationURL, type: .video) else {
            throw SecretFilesError.sourceFileAccessError("Could not create media")
        }
        do {
            let destinationHandler = try FileLikeHandler(media: destinationMedia, mode: .writing)
            let sourceHandler = try FileLikeHandler(media: sourceMedia, mode: .reading)

            try destinationHandler.prepareIfDoesNotExist()
            let header = streamEnc.header()
            try destinationHandler.write(contentsOf: Data(header))
            var writeBlockSizeOperation: (([UInt8]) -> Void)?
            writeBlockSizeOperation = { cipherText in

                let cipherTextLength = withUnsafeBytes(of: cipherText.count) {
                    Array($0)
                }
                try! destinationHandler.write(contentsOf: Data(cipherTextLength))
                writeBlockSizeOperation = nil
            }
            return try await withCheckedThrowingContinuation { continuation in

                ChunkedFileProcessingPublisher(sourceFileHandle: sourceHandler, blockSize: defaultBlockSize)
                    .map({ (bytes, progress, isFinal)  -> Data in
                        let message = streamEnc.push(message: bytes, tag: isFinal ? .FINAL : .MESSAGE)!
                        writeBlockSizeOperation?(message)
                        self.progressSubject.send(progress)
                        return Data(message)
                    }).sink { signal in
                        switch signal {

                        case .finished:
                            guard let media = EncryptedMedia(source: destinationURL) else {
                                continuation.resume(throwing: SecretFilesError.sourceFileAccessError("Could not create media"))
                                return
                            }
                            continuation.resume(returning: media)
                        case .failure(_):
                            continuation.resume(throwing: SecretFilesError.encryptError)
                        }
                    } receiveValue: { data in
                        try? destinationHandler.write(contentsOf: data)
                    }.store(in: &self.cancellables)
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
