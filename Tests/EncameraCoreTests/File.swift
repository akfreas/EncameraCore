//
//  File.swift
//  
//
//  Created by Alexander Freas on 13.02.24.
//

import Foundation
import XCTest
import Sodium
import Combine
@testable import EncameraCore

class SecretFileHandlerTests: XCTestCase {
    private var key: Array<UInt8>!
    private let directoryModel = DemoDirectoryModel() // Make sure this is your actual model for handling directories
    private var key2: Array<UInt8>!


    override func setUp() {
        super.setUp()
        // Generate a new encryption key using your preferred method or library
        key = Sodium().secretStream.xchacha20poly1305.key()
        key2 = Sodium().secretStream.xchacha20poly1305.key()
        try? directoryModel.initializeDirectories()
    }

    func testRoundTripEncryptionDecryption() async throws {
        // Step 1: Prepare the source file
        let sourceFileURL = try FileUtils.createNewMovieFile()
        let targetEncryptURL = directoryModel.driveURLForNewMedia(sourceFileURL)
        let targetDecryptURL = directoryModel.driveURLForNewMedia(sourceFileURL).appendingPathExtension("decrypted")

        // Step 2: Encrypt the file
        var encryptHandler = SecretFileHandler(keyBytes: key, source: sourceFileURL, targetURL: targetEncryptURL)
        let encryptedFile = try await encryptHandler.encrypt()

        // Step 3: Decrypt the file
        let decryptHandler = SecretFileHandler(keyBytes: key, source: encryptedFile, targetURL: targetDecryptURL)
        let decryptedFileURL: CleartextMedia<URL> = try await decryptHandler.decrypt()

        // Step 4: Compare the original and decrypted file contents

        let originalContent = try Data(contentsOf: URL(fileURLWithPath: sourceFileURL.source.path()))
        let decryptedContent = try Data(contentsOf: URL(fileURLWithPath: decryptedFileURL.source.path()))

        XCTAssertEqual(originalContent, decryptedContent, "The decrypted file content does not match the original content.")

//
//        let originalContent = sourceFileURL.source
//        let decryptedContent = decryptedFileURL.source
//        XCTAssertTrue(FileManager.default.contentsEqual(atPath: originalContent.path(), andPath: decryptedContent.path()))
    }
}
