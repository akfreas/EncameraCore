//
//  VideoFilesManagerTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 02.05.22.
//

import Foundation
import XCTest
import Sodium
import Combine
@testable import EncameraCore


class ReEncrypterTests: XCTestCase {
    var cancellables: [AnyCancellable] = []
    private var key1: Array<UInt8>!
    private var key2: Array<UInt8>!

    private let directoryModel = DemoDirectoryModel()

    override func setUp() {
        super.setUp()
        key1 = Sodium().secretStream.xchacha20poly1305.key()
        key2 = Sodium().secretStream.xchacha20poly1305.key()
        try? directoryModel.initializeDirectories()
    }

    func testReEncryptFiles() async throws {
        let sourceMedia = try FileUtils.createNewMovieFile()

        // Encrypt the file with the first key
        let encryptHandler = SecretFileHandler(keyBytes: key1, source: sourceMedia, targetURL: directoryModel.driveURLForNewMedia(sourceMedia))
        let encrypted = try await encryptHandler.encrypt()
        let dc1 = SecretFileHandler(keyBytes: key1, source: encrypted, targetURL:
                                        URL.tempMediaDirectory
            .appendingPathComponent(sourceMedia.id))
        let decrypted1: CleartextMedia<URL> = try await dc1.decrypt()
        print("Source url: \(sourceMedia.source.path()), decrypted1 url: \(decrypted1.source.path())")

        XCTAssertTrue(FileManager.default.contentsEqual(atPath: decrypted1.source.path(), andPath: sourceMedia.source.path()))

        let en1 = SecretFileHandler(keyBytes: key2, source: decrypted1, targetURL: directoryModel.driveURLForNewMedia(sourceMedia))
        let encrypted1 = try await en1.encrypt()

        let dc2 = SecretFileHandler(keyBytes: key2, source: encrypted1, targetURL: directoryModel.driveURLForNewMedia(sourceMedia))
        let decrypted2: CleartextMedia<URL> = try await dc2.decrypt()
        print("Source url: \(sourceMedia.source.path()), decrypted url: \(decrypted2.source.path())")
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: decrypted2.source.path(), andPath: sourceMedia.source.path()))

//        // Re-encrypt the file with the second key
//        let reEncrypter = ReEncrypter(sourceKey: PrivateKey(name: "source", keyBytes: key1, creationDate: Date()), targetKey: PrivateKey(name: "target", keyBytes: key2, creationDate: Date()))
//        let reEncrypted = try await reEncrypter.reEncryptFiles(fileList: [encrypted])
//
//        let reEncryptedFile = try XCTUnwrap(reEncrypted.first)
//
//        // Decrypt the re-encrypted file
//        let decryptHandler = SecretFileHandler(keyBytes: key2, source: reEncryptedFile, targetURL: directoryModel.driveURLForNewMedia(sourceMedia))
//        let decrypted: CleartextMedia<URL> = try await decryptHandler.decrypt()
//
//        // Verify file content equality
//        let originalContent = try Data(contentsOf: URL(fileURLWithPath: sourceMedia.source.path()))
//        let decryptedContent = try Data(contentsOf: URL(fileURLWithPath: decrypted.source.path()))
//        print("sourceMedia.source.path() \(sourceMedia.source.path())")
//        print("decrypted.source.path() \(decrypted.source.path())")
//        XCTAssertEqual(originalContent, decryptedContent, "The decrypted file content does not match the original content.")
    }
}



class FileOperationsTests: XCTestCase {
    
    var cancellables: [AnyCancellable] = []
    private var key: Array<UInt8>!

    private let directoryModel = DemoDirectoryModel()

    override func setUp() {
        key = Sodium().secretStream.xchacha20poly1305.key()
        try? directoryModel.initializeDirectories()
    }
    
    func testEncryptInMemory() async throws {
        let sourceMedia = try FileUtils.createNewDataImageMedia()
        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia, targetURL: directoryModel.driveURLForNewMedia(sourceMedia))

        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))

    }
    
    func testEncryptVideo() async throws {
        
        
        let sourceMedia = try FileUtils.createNewMovieFile()

        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia, targetURL: directoryModel.driveURLForNewMedia(sourceMedia))
        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
    }
    
    func testDecryptVideo() async throws {
        
        let sourceMedia = try FileUtils.createNewMovieFile()

        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia, targetURL: directoryModel.driveURLForNewMedia(sourceMedia))
        let encrypted = try await handler.encrypt()
        let target = TempFilesManager(subdirectory: "testing_1").createTempURL(for: .video, id: sourceMedia.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
        let decryptHandler = SecretFileHandler(keyBytes: key, source: encrypted, targetURL: target)
        let decrypted: CleartextMedia<URL> = try await decryptHandler.decrypt()
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: decrypted.source.path))
    }
    
}
