//
//  MultipleKeyKeychainManager.swift
//  Encamera
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation
import Sodium
import Combine

private enum KeychainConstants {
    static let applicationTag = "com.encamera.key"
    static let account = "encamera"
    static let minKeyLength = 2
}


public class MultipleKeyKeychainManager: ObservableObject, KeyManager {

    
    
    public var isAuthenticated: AnyPublisher<Bool, Never>
    private var authenticated: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var sodium = Sodium()
    private var passwordValidator = PasswordValidator()
    public var keyDirectoryStorage: DataStorageSetting
    private (set) public var currentKey: PrivateKey?  {
        didSet {
            keySubject.send(currentKey)
        }
    }
    public var keyPublisher: AnyPublisher<PrivateKey?, Never> {
        keySubject.eraseToAnyPublisher()
    }
    
    private var keySubject: PassthroughSubject<PrivateKey?, Never> = .init()
    
    required public init(isAuthenticated: AnyPublisher<Bool, Never>, keyDirectoryStorage: DataStorageSetting) {
        self.isAuthenticated = isAuthenticated
        self.keyDirectoryStorage = keyDirectoryStorage
        self.isAuthenticated.sink { newValue in
            self.authenticated = newValue
            do {
                try self.checkAuthenticated {
                    try self.setActiveKey(nil)
                }
                try self.getActiveKeyAndSet()
            } catch {
                debugPrint("Error getting/setting active key", error)
            }
        }.store(in: &cancellables)

    }
    
    public func clearKeychainData() {
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        
        let _ = SecItemDelete(query as CFDictionary)
        
        
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword
        ]
        
        let _ = SecItemDelete(passwordQuery as CFDictionary)
        
        try? setActiveKey(nil)
        print("Keychain data cleared")
    }
    
    @discardableResult public func generateNewKey(name: String, storageType: StorageType, backupToiCloud: Bool = false) throws -> PrivateKey {
        
        try checkAuthenticated()
        
        try validateKeyName(name: name)
        
        let bytes = Sodium().secretStream.xchacha20poly1305.key()
        
        let key = PrivateKey(name: name, keyBytes: bytes, creationDate: Date())
        var setNewKeyToCurrent: Bool
        do {
            let storedKeys = try storedKeys()
            setNewKeyToCurrent = storedKeys.count == 0
        } catch {
            setNewKeyToCurrent = true
        }
        try save(key: key,
                 storageType: storageType,
                 setNewKeyToCurrent: setNewKeyToCurrent,
                 backupToiCloud: backupToiCloud)
        return key
    }
    
    public func validateKeyName(name: String) throws {
        guard name.count > KeychainConstants.minKeyLength else {
            throw KeyManagerError.keyNameError
        }
    }
    
    public func createBackupDocument() throws -> String {
        let keys = try storedKeys()
        
        return keys.map { key in
            return "Name: \(key.name)\nCode:\n\(key.base64String ?? "invalid")"
        }.joined(separator: "\n").appending("\n\nCopy the code into the \"Key Entry\" form in the app to use it again.")
    }
    
    public func save(key: PrivateKey, storageType: StorageType, setNewKeyToCurrent: Bool, backupToiCloud: Bool) throws {
        var query = key.keychainQueryDictForKeychain
        
        if backupToiCloud {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        } else {
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        }
        
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        try checkStatus(status: status)
        keyDirectoryStorage.setStorageTypeFor(keyName: key.name, directoryModelType: storageType)

        if setNewKeyToCurrent {
            try setActiveKey(key.name)
        }
    }

    public func update(key: PrivateKey, backupToiCloud: Bool) throws {
        try checkAuthenticated()
        let updateDict = createKeychainQueryForWrite(with: key, backupToiCloud: backupToiCloud)
        let query = try updateKeyQuery(for: key.name)
        let status = SecItemUpdate(query, updateDict)
        try checkStatus(status: status)
    }
    
    public func storedKeys() throws -> [PrivateKey] {
        try checkAuthenticated()
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try checkStatus(status: status)


        guard let keychainItems = item as? [[String: Any]] else {
            throw KeyManagerError.dataError
        }
        let keys = keychainItems.compactMap { keychainItem -> PrivateKey? in
            do {
                return try PrivateKey(keychainItem: keychainItem)
            } catch {
                return nil
            }
        }.sorted(by: {
            $1.creationDate.compare($0.creationDate) == .orderedDescending
        })
        return keys
    }
    
    public func deleteKey(_ key: PrivateKey) throws {
        try checkAuthenticated()
        let key = try getKey(by: key.name)
        let query = key.keychainQueryDictForKeychain
        let status = SecItemDelete(query as CFDictionary)
        try checkStatus(status: status, defaultError: .deleteKeychainItemsFailed)
        if currentKey?.name == key.name {
            try setActiveKey(nil)
        }
    }
    
    public func setActiveKey(_ name: KeyName?) throws {
        try checkAuthenticated {
            self.currentKey = nil
        }
        guard let name = name else {
            currentKey = nil
            UserDefaultUtils.removeObject(forKey: UserDefaultKey.currentKey)
            return
        }
        guard let key = try? getKey(by: name) else {
            throw KeyManagerError.notFound
        }
        currentKey = key
        UserDefaultUtils.set(key.name, forKey: UserDefaultKey.currentKey)
    }
    
    func getActiveKey() throws -> PrivateKey {
        guard let activeKeyName = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String else {
            guard let firstStoredKey = try? storedKeys().first else {
                throw KeyManagerError.notFound
            }
            try setActiveKey(firstStoredKey.name)
            return firstStoredKey
        }
        return try getKey(by: activeKeyName)
    }
    
    func getKey(by keyName: KeyName) throws -> PrivateKey {

        try checkAuthenticated()
        
        let query = try getKeyQuery(for: keyName)
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try checkStatus(status: status)

        guard let keychainItem = item as? [String: Any]
               else {
            throw KeyManagerError.dataError
        }
        let key = try PrivateKey(keychainItem: keychainItem)
        return key

    }
    
    public func passwordExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        do {
            try checkStatus(status: status)
        } catch is KeyManagerError {
            
        } catch {
            debugPrint("Key error", error)
        }
        return item != nil
    }
    
    public func setPassword(_ password: String) throws {
        let hashed = try hashFrom(password: password)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecValueData as String: hashed
        ]
        let setPasswordStatus = SecItemAdd(query as CFDictionary, nil)
        
        try checkStatus(status: setPasswordStatus)
    }
    
    public func changePassword(newPassword: String, existingPassword: String) throws {
        guard try checkPassword(existingPassword) == true else {
            throw KeyManagerError.invalidPassword
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
        ]
        let deletePasswordStatus = SecItemDelete(query as CFDictionary)
        do {
            try checkStatus(status: deletePasswordStatus)
        } catch {
            debugPrint("Clearing password failed", error)
        }
        try setPassword(newPassword)
    }
    
    public func checkPassword(_ password: String) throws -> Bool {
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        do {
            try checkStatus(status: status)
            guard let item = item, let passwordData = item as? Data,
                  let hashString = String(data: passwordData, encoding: .utf8) else {
                throw KeyManagerError.notFound
            }
            let passwordBytes = password.bytes
            let passwordMatch = sodium.pwHash.strVerify(hash: hashString, passwd: passwordBytes)
            if passwordMatch != true {
                throw KeyManagerError.invalidPassword
            }
            return passwordMatch
        }
        catch let managerError as KeyManagerError {
            if case .notFound = managerError {
                throw KeyManagerError.invalidPassword
            } else {
                throw managerError
            }
        }
        catch {
            debugPrint("error checking password", error)
        }
        return false
    }
    
    
}

private extension MultipleKeyKeychainManager {
    func checkStatus(status: OSStatus, defaultError: KeyManagerError = .unhandledError) throws {
        determineOSStatus(status: status)
        switch status {
        case errSecItemNotFound:
            throw KeyManagerError.notFound
        case errSecDuplicateItem:
            throw KeyManagerError.keyExists
        case errSecSuccess:
            break
        default:
            throw defaultError
        }
    }
    
    func hashFrom(password: String) throws -> Data {
        let bytes = password.bytes
        let hashString = sodium.pwHash.str(passwd: bytes,
                                           opsLimit: sodium.pwHash.OpsLimitInteractive,
                                                 memLimit: sodium.pwHash.MemLimitInteractive)
        guard let hashed = hashString?.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        return hashed
    }
    
    func bytes(from string: String) throws -> [UInt8] {
        guard let passwordData = string.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        
        var bytes = [UInt8](repeating: 0, count: passwordData.count)
        passwordData.copyBytes(to: &bytes, count: string.count)
        return bytes
    }
    
    private func getActiveKeyAndSet() throws {
       
        let keyObject = try getActiveKey()
        
        try setActiveKey(keyObject.name)
    }
    
    private func getKeyQuery(for keyName: KeyName) throws -> CFDictionary {
        guard let keyData = keyName.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecAttrLabel as String: keyData,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        return query as CFDictionary
    }
    
    private func updateKeyQuery(for keyName: KeyName) throws -> CFDictionary {
        guard let keyData = keyName.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: keyData,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        return query as CFDictionary

    }
    
    private func createKeychainQueryForWrite(with key: PrivateKey, backupToiCloud: Bool) -> CFDictionary {
        var query = key.keychainQueryDictForKeychain
        if backupToiCloud {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        } else {
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        }
        return query as CFDictionary
    }
    
    private func checkAuthenticated(_ nonAuthenticatedAction: (() throws -> Void)? = nil) throws {
        guard authenticated == true else {
            try nonAuthenticatedAction?()
            throw KeyManagerError.notAuthenticatedError
        }
    }
}

private extension PrivateKey {
    
    var keychainQueryDict: [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: name.data(using: .utf8)!,
            kSecAttrCreationDate as String: creationDate,
            kSecValueData as String: Data(keyBytes)
        ]
    }
    
    var applicationLabel: String {
        "\(KeychainConstants.applicationTag).\(name)"
    }
    
    var keychainQueryDictForKeychain: [String: Any] {
        var query = keychainQueryDict
        query[kSecAttrApplicationLabel as String] = applicationLabel
        return query
    }
}
