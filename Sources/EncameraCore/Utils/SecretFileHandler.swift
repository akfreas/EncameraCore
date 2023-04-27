//
//  SecretFilesManager.swift
//  Encamera
//
//  Created by Alexander Freas on 28.04.22.
//

import Foundation
import Sodium
import Combine


public enum SecretFilesError: Error {
    case keyError
    case encryptError
    case decryptError
    case sourceFileAccessError
    case destinationFileAccessError
    case createThumbnailError
    case createVideoThumbnailError
    case fileTypeError
    case createPreviewError
}


protocol SecretFileHandling {
    
    associatedtype SourceMediaType: MediaDescribing
    
    var progress: AnyPublisher<Double, Never> { get }
    var sourceMedia: SourceMediaType { get }
    var keyBytes: Array<UInt8> { get }
    var sodium: Sodium { get }
    func encrypt() async throws -> EncryptedMedia
    func decrypt<T: MediaSourcing>() async throws -> CleartextMedia<T>

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
    
    
    func decryptPublisher() -> AnyPublisher<Data, Error> {

        do {
            let fileHandler = try FileLikeHandler(media: sourceMedia, mode: .reading)
            let headerBytesCount = 24
            let headerBytes = try fileHandler.read(upToCount: headerBytesCount)
            var headerBuffer = [UInt8](repeating: 0, count: headerBytesCount)
            headerBytes?.copyBytes(to: &headerBuffer, count: headerBytesCount)
            
            let blockSizeInfo = try fileHandler.read(upToCount: 8)
            let blockSize: UInt32 = blockSizeInfo!.withUnsafeBytes({ $0.load(as: UInt32.self)
            })
            
            guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: headerBuffer) else {
                debugPrint("Could not create stream with key")
                return Fail(error: SecretFilesError.keyError).eraseToAnyPublisher()
            }
            
            return ChunkedFileProcessingPublisher(sourceFileHandle: fileHandler, blockSize: Int(blockSize)).tryMap { (bytes, progress, _) -> Data in
                guard let (message, _) = streamDec.pull(cipherText: bytes) else {
                    throw SecretFilesError.decryptError
                }
                progressSubject.send(progress)
                   return Data(message)
            }.eraseToAnyPublisher()
        } catch {
            debugPrint("error decrypting", error)
            return Fail(error: SecretFilesError.decryptError).eraseToAnyPublisher()
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
        
    func decrypt<T>() async throws -> CleartextMedia<T> where T : MediaSourcing {
        switch T.self {
        case is URL.Type:
            return try await decryptFile() as! CleartextMedia<T>
        case is Data.Type:
            return try await decryptInMemory() as! CleartextMedia<T>
        default:
            fatalError()
        }
    }
    
    
    
    @discardableResult func encrypt() async throws -> EncryptedMedia {
                
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            debugPrint("Could not create stream with key")
            throw SecretFilesError.encryptError
        }
        guard let destinationURL = targetURL,
              let destinationMedia = EncryptedMedia(source: destinationURL, type: .video) else {
            throw SecretFilesError.sourceFileAccessError
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
                                continuation.resume(throwing: SecretFilesError.sourceFileAccessError)
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
            throw SecretFilesError.sourceFileAccessError
        }
    }
    
   
}

private extension SecretFileHandler {
    
    private func decryptInMemory() async throws -> CleartextMedia<Data>  {

        return try await withCheckedThrowingContinuation { continuation in
            
            self.decryptPublisher().reduce(Data()) { accum, next in
                accum + next
            }.sink { complete in
                switch complete {
                    
                case .finished:
                    break
                case .failure(_):
                    continuation.resume(throwing: SecretFilesError.decryptError)
                }
                
            } receiveValue: { [self] data in
                let image = CleartextMedia(source: data, mediaType: self.sourceMedia.mediaType, id: self.sourceMedia.id)
                continuation.resume(returning: image)
            }.store(in: &self.cancellables)
        }
    }
    
    private func decryptFile() async throws -> CleartextMedia<URL> {
        guard let destinationURL = self.targetURL else {
            throw SecretFilesError.sourceFileAccessError
        }
        do {
            let destinationMedia = CleartextMedia(source: destinationURL)
            let destinationHandler = try FileLikeHandler(media: destinationMedia, mode: .writing)
            try destinationHandler.prepareIfDoesNotExist()
            

            return try await withUnsafeThrowingContinuation { continuation in
                
                self.decryptPublisher()
                    .sink { recieveCompletion in
                        switch recieveCompletion {
                        case .finished:
                            let media = CleartextMedia(source: destinationURL)
                            continuation.resume(returning: media)
                        case .failure(_):
                            continuation.resume(throwing: SecretFilesError.decryptError)
                        }
                } receiveValue: { data in
                    do {
                        try destinationHandler.write(contentsOf: data)
                    } catch {
                        continuation.resume(throwing: SecretFilesError.destinationFileAccessError)
                    }
                }.store(in: &self.cancellables)
            }
            
        } catch {
            try FileManager.default.removeItem(at: destinationURL)
            throw SecretFilesError.destinationFileAccessError
        }
    }

}

