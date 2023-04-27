//
//  KeychainTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 22.06.22.
//

import Foundation
import XCTest
import Combine
@testable import EncameraCore


class KeychainTests: XCTestCase {
    
    var keyManager: MultipleKeyKeychainManager = MultipleKeyKeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())
    
    override func setUp() async throws {
        try? keyManager.clearKeychainData()
        try? keyManager.clearPassword()
    }
    
    override func tearDown() {
        try? keyManager.clearKeychainData()
        try? keyManager.clearPassword()
    }

    
    func testStoreMultipleKeys() throws {
        try keyManager.generateNewKey(name: "test1", storageType: .local)
        try keyManager.generateNewKey(name: "test2", storageType: .local)
        
        let storedKeys = try keyManager.storedKeys()
        
        XCTAssertEqual(storedKeys.count, 2)
        XCTAssertEqual(storedKeys[0].name, "test1")
        XCTAssertEqual(storedKeys[1].name, "test2")
    }
    
    func testSelectCurrentKey() throws {
        try keyManager.generateNewKey(name: "test4", storageType: .local)
        try keyManager.generateNewKey(name: "test5", storageType: .local)

        try keyManager.setActiveKey("test5")
        
        let activeKey = try keyManager.getActiveKey()
        XCTAssertEqual(activeKey.name, "test5")
        XCTAssertNotNil(activeKey.keyBytes)
    }
    
    func testDeleteKeyByName() throws {
        try keyManager.generateNewKey(name: "test1_key", storageType: .local)
        let key = try keyManager.generateNewKey(name: "test2_key", storageType: .local)

        try keyManager.deleteKey(key)
        
        let storedKeys = try keyManager.storedKeys()

        XCTAssertEqual(storedKeys.count, 1)
        XCTAssertEqual(storedKeys.first!.name, "test1_key")
    }
    
    func testGenerateNewKeySetsCurrentKey() throws {
        
        let newKey = try keyManager.generateNewKey(name: "test1_key", storageType: .local)

        XCTAssertEqual(keyManager.currentKey, newKey)
        let activeKey = try XCTUnwrap(keyManager.getActiveKey())
        XCTAssertEqual(activeKey, newKey)
    }
    
    func testGenerateNewKeySetsCurrentKeyInUserDefaults() throws {
        
        let newKey = try keyManager.generateNewKey(name: "test1_key", storageType: .local)

        XCTAssertEqual(keyManager.currentKey, newKey)
        let activeKey = try XCTUnwrap(UserDefaultUtils.value(forKey: .currentKey) as? String)
        XCTAssertEqual(activeKey, newKey.name)
    }
    
    func testGenerateNewKeySetsActiveKeyWithoutUserDefaults() throws {
        
        let newKey = try keyManager.generateNewKey(name: "test1_key", storageType: .local)
        UserDefaultUtils.removeObject(forKey: .currentKey)
        let activeKey = try XCTUnwrap(keyManager.getActiveKey())
        XCTAssertEqual(activeKey, newKey)
    }
    
    func testDeleteKeyUnsetsCurrentKey() throws {
        let newKey = try keyManager.generateNewKey(name: "test1_key", storageType: .local)

        try keyManager.deleteKey(newKey)
        
        XCTAssertNil(keyManager.currentKey)
        XCTAssertThrowsError(try keyManager.getActiveKey())
    }
    
    func testGenerateMutipleNewKeysSetsFirstKeyAsCurrentKey() throws {
        
        let newKey = try keyManager.generateNewKey(name: "test1_key", storageType: .local)
        try keyManager.generateNewKey(name: "test2_key", storageType: .local)
        XCTAssertEqual(keyManager.currentKey, newKey)
        let activeKey = try XCTUnwrap(keyManager.getActiveKey())
        XCTAssertEqual(activeKey, newKey)
    }
    
    func testGeneratingNewKeyWithExistingNameThrowsError() throws {
        try keyManager.generateNewKey(name: "test1_key", storageType: .local)
        XCTAssertThrowsError(try keyManager.generateNewKey(name: "test1_key", storageType: .local))
        
    }
    
    func testInitSetsCurrentKeyIfAuthenticated() throws {
        
        let key = try keyManager.generateNewKey(name: "test1_key", storageType: .local)
        try keyManager.setActiveKey(key.name)
        let subject = PassthroughSubject<Bool, Never>()
        let newManager = MultipleKeyKeychainManager(isAuthenticated: subject.eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())
        subject.send(true)
        
        XCTAssertEqual(newManager.currentKey, key)
        
    }
    
    func testInitDoesNotSetCurrentKeyIfNotAuthenticated() throws {
        
        try keyManager.generateNewKey(name: "test1_key", storageType: .local)

        let newManager = MultipleKeyKeychainManager(isAuthenticated: Just(false).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())
        
        XCTAssertNil(newManager.currentKey)
        
    }
    
    func testCreateBackupDocument() throws {
        try keyManager.generateNewKey(name: "test4", storageType: .local)
        try keyManager.generateNewKey(name: "test5", storageType: .local)

        let doc = try keyManager.createBackupDocument()
        
        print(doc)
    }
    
    func testSetPassword() throws {
        
        try keyManager.setPassword("q1w2e3r4")
    }
    
    func testCheckPasswordPositive() throws {
        let password = "r4t5y6y6"
        try keyManager.setPassword(password)
        
        let result = try keyManager.checkPassword(password)
        XCTAssertTrue(result)
    }
    
    func testCheckPasswordNegative() throws {
        let password = "r4t5y6y6"
        try keyManager.setPassword(password)
        
        let result = XCTAssertThrowsError(try keyManager.checkPassword("wrong")) { error in
            XCTAssertEqual(error as! KeyManagerError, .invalidPassword)
        }
    }
    
    func testChangePassword() throws {
        let firstPassword = "q1w2e3r4"
        try keyManager.setPassword(firstPassword)
        let newPassword = "r4t5y6y6"
        try keyManager.changePassword(newPassword: newPassword, existingPassword: firstPassword)
        
        XCTAssertThrowsError(try keyManager.checkPassword(firstPassword)) { error in
            XCTAssertEqual(error as! KeyManagerError, .invalidPassword)
        }
        XCTAssertTrue(try keyManager.checkPassword(newPassword))
    }
    
    func testChangePasswordIncorrectExistingPassword() throws {
        let firstPassword = "q1w2e3r4"
        try keyManager.setPassword(firstPassword)
        let newPassword = "r4t5y6y6"
        XCTAssertThrowsError(try keyManager.changePassword(newPassword: newPassword, existingPassword: "blabla")) { error in
            XCTAssertEqual(error as! KeyManagerError, KeyManagerError.invalidPassword)
        }
        
        XCTAssertTrue(try keyManager.checkPassword(firstPassword))

    }
    
    func testCheckIfPasswordExists() throws {
        let firstPassword = "q1w2e3r4"
        try keyManager.setPassword(firstPassword)

        XCTAssertTrue(keyManager.passwordExists())
    }
    
    func testCheckIfPasswordDoesNotExist() throws {
        XCTAssertFalse(keyManager.passwordExists())
    }
    
    func testCannotSetPasswordIfExists() throws {
        let firstPassword = "q1w2e3r4"
        try keyManager.setPassword(firstPassword)
        let newPassword = "r4t5y6y6"
        XCTAssertThrowsError(try keyManager.setPassword(newPassword))
    }
    

}

private extension MultipleKeyKeychainManager {
    func clearPassword() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            throw KeyManagerError.deleteKeychainItemsFailed
        }

    }
}
