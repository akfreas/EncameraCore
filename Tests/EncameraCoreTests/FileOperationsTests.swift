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
        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia, targetURL: directoryModel.driveURLForMedia(sourceMedia))

        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))

    }
    
    func testEncryptVideo() async throws {
        
        
        let sourceMedia = try FileUtils.createNewMovieFile()

        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia, targetURL: directoryModel.driveURLForMedia(sourceMedia))
        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
    }
    
    func testDecryptVideo() async throws {
        
        let sourceMedia = try FileUtils.createNewMovieFile()

        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia, targetURL: directoryModel.driveURLForMedia(sourceMedia))
        let encrypted = try await handler.encrypt()
        let target = TempFilesManager(subdirectory: "testing_1").createTempURL(for: .video, id: sourceMedia.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
        let decryptHandler = SecretFileHandler(keyBytes: key, source: encrypted, targetURL: target)
        let decrypted: CleartextMedia<URL> = try await decryptHandler.decrypt()
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: decrypted.source.path))
    }
    
}
