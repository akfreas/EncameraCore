//
//  KeychainManager.swift
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
    static let passPhraseKeyItem = "encamera_key_passphrase"
}

struct KeychainItem {
    let name: String
    let creationDate: Date
    let type: String
    let storageType: String
}

public struct KeyPassphrase: Codable {
    public let words: [String]
    public let iCloudBackupEnabled: Bool
}


public class KeychainManager: ObservableObject, KeyManager {

    

    public var isAuthenticated: AnyPublisher<Bool, Never>
    private var cancellables = Set<AnyCancellable>()
    private var sodium = Sodium()

    private var passwordValidator = PasswordValidator()
    private(set) public var currentKey: PrivateKey? {
        didSet {
            keySubject.send(currentKey)
        }
    }
    public var keyPublisher: AnyPublisher<PrivateKey?, Never> {
        keySubject.eraseToAnyPublisher()
    }

    public var areKeysStoredIniCloud: Bool  {
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizable
        ]

        do {
            let keys = try keysFromQuery(query: keyQuery)
            return keys.count > 0
        } catch {
            print("Error fetching keys: \(error)")
            return false
        }
    }

    private var keySubject: PassthroughSubject<PrivateKey?, Never> = .init()
    
    required public init(isAuthenticated: AnyPublisher<Bool, Never>) {
        self.isAuthenticated = isAuthenticated
        self.isAuthenticated.sink { newValue in
            do {
                try self.getActiveKeyAndSet()
            } catch {
                debugPrint("Error getting/setting active key", error)
            }
        }.store(in: &cancellables)
    }

    public func clearKeychainData() {
        let keychainClasses: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]

        for keychainClass in keychainClasses {
            let query: [String: Any] = [
                kSecClass as String: keychainClass
            ]

            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                print("Failed to delete items for class \(keychainClass): \(status)")
            }
        }

        let passphraseStatus = SecItemDelete(queryForPassphrase() as CFDictionary)
        if passphraseStatus != errSecSuccess && passphraseStatus != errSecItemNotFound {
            print("Failed to delete passphrase item: \(passphraseStatus)")
        }

        try? setActiveKey(nil)
        print("Keychain data cleared")
    }


    @discardableResult public func generateKeyUsingRandomWords(name: String) throws -> PrivateKey {
        
        guard let dictionaryPath = Bundle.main.path(forResource: "dictionary", ofType: "txt"),
              let dictionaryContent = try? String(contentsOfFile: dictionaryPath) else {
            throw KeyManagerError.dictionaryLoadError
        }

        let words = dictionaryContent.components(separatedBy: .newlines).filter { !$0.isEmpty && $0.lengthOfBytes(using: .utf8) > 4 }

        guard words.count >= 10 else {
            throw KeyManagerError.dictionaryTooSmall
        }

        let selectedWords = (0..<10).compactMap { _ in words.randomElement()?.lowercased() }

        return try generateKeyFromPasswordComponents(selectedWords, name: name)
    }

    @discardableResult public func saveKeyWithPassphrase(passphrase: KeyPassphrase) throws -> PrivateKey {
        
        return try generateKeyFromPasswordComponents(passphrase.words, name: AppConstants.defaultKeyName)
    }

    @discardableResult public func generateKeyFromPasswordComponents(_ components: [String], name: String) throws -> PrivateKey {
        guard !components.isEmpty else {
            throw KeyManagerError.invalidInput
        }

        try validateKeyName(name: name)
        let splitIndex = 4
        let fullPassword = components.joined(separator: "-")
        let saltComponents = components.prefix(splitIndex)
        let saltString = saltComponents.joined(separator: "-")
        let passwordComponents = components.dropFirst(splitIndex)
        let password = passwordComponents.joined(separator: "-")

        // Convert salt string to bytes, ensuring it matches the required salt length
        let saltBytes = Array(saltString.bytes.prefix(Sodium().pwHash.SaltBytes))
        if saltBytes.count < Sodium().pwHash.SaltBytes {
            throw KeyManagerError.invalidSalt
        }

        let keyLength = Sodium().secretStream.xchacha20poly1305.KeyBytes
        guard let keyBytes = sodium.pwHash.hash(outputLength: keyLength,
                                                  passwd: password.bytes,
                                                  salt: saltBytes,
                                                  opsLimit: sodium.pwHash.OpsLimitInteractive,
                                                  memLimit: sodium.pwHash.MemLimitInteractive) else {
            throw KeyManagerError.keyDerivationFailed
        }

        let key = PrivateKey(name: name, keyBytes: keyBytes, creationDate: Date())
        
        try save(key: key, setNewKeyToCurrent: true, backupToiCloud: areKeysStoredIniCloud)

        // Save or update the passphrase in the keychain
        let passphraseData = fullPassword.data(using: .utf8)!
        let passphraseQuery = queryForPassphrase(additionalQuery: [:])

        var withOptions: [String: Any] = passphraseQuery
        withOptions[kSecReturnData as String] = true

        var item: CFTypeRef?
        let queryResult = SecItemCopyMatching(withOptions as CFDictionary, &item)

        switch queryResult {
        case errSecSuccess:
            // Passphrase exists, update it
            let updateQuery: [String: Any] = [kSecValueData as String: passphraseData]
            let updateStatus = SecItemUpdate(passphraseQuery as CFDictionary, updateQuery as CFDictionary)

            try checkStatus(status: updateStatus)
        case errSecItemNotFound:
            // Passphrase does not exist, add it
            let addQuery = queryForPassphrase(additionalQuery: [
                kSecValueData as String: passphraseData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ])
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            try checkStatus(status: addStatus)
        default:
            // Handle other errors
            try checkStatus(status: queryResult)
        }

        return key

    }

    public func retrieveKeyPassphrase() throws -> KeyPassphrase {
        let query: [String: Any] = queryForPassphrase(additionalQuery: [
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,  // Include attributes in the result
            kSecMatchLimit as String: kSecMatchLimitOne
        ])

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw KeyManagerError.notFound
        }

        guard let result = item as? [String: Any],
              let data = result[kSecValueData as String] as? Data,
              let passphrase = String(data: data, encoding: .utf8) else {
            throw KeyManagerError.dataError
        }

        let words = passphrase.components(separatedBy: "-")

        // Check if the item is stored in iCloud
        let isStoredInICloud = (result[kSecAttrSynchronizable as String] as? Bool) == true

        let keyPassphrase = KeyPassphrase(words: words, iCloudBackupEnabled: isStoredInICloud)

        return keyPassphrase
    }

    public func validateKeyName(name: String) throws {
        guard name.count > KeychainConstants.minKeyLength else {
            throw KeyManagerError.keyNameError
        }
    }
    
    public func save(key: PrivateKey, setNewKeyToCurrent: Bool, backupToiCloud: Bool) throws {
        if let existingKey = try? getKey(by: key.name) {
            let updateQuery: [String: Any] = [kSecValueData as String: Data(key.keyBytes)]
            let updateStatus = SecItemUpdate(existingKey.keychainQueryDictForKeychain as CFDictionary, updateQuery as CFDictionary)
            try checkStatus(status: updateStatus)

        } else {

            let addStatus = SecItemAdd(key.keychainQueryDictForKeychain as CFDictionary, nil)
            try checkStatus(status: addStatus)

        }

        if setNewKeyToCurrent {
            try setActiveKey(key.name)
        }
    }

    public func backupKeychainToiCloud(backupEnabled: Bool) throws {
        

        let keys = try storedKeys()
        for key in keys {
            try update(key: key, backupToiCloud: backupEnabled)
        }
        let updateQuery = [kSecAttrSynchronizable as String: backupEnabled ? kCFBooleanTrue : kCFBooleanFalse]
        let updateStatus = SecItemUpdate(queryForPassphrase() as CFDictionary, updateQuery as CFDictionary)

        try checkStatus(status: updateStatus)

    }

    public func update(key: PrivateKey, backupToiCloud: Bool) throws {
        
        var updateDict: [String: Any] = [:]
        if backupToiCloud {
            updateDict[kSecAttrSynchronizable as String] = kCFBooleanTrue
        } else {
            updateDict[kSecAttrSynchronizable as String] = kCFBooleanFalse
        }
        let query = try updateKeyQuery(for: key.name)
        
        let status = SecItemUpdate(query, updateDict as CFDictionary)
        try checkStatus(status: status)
        debugPrint("Key updated: \(key.name), iCloud: \(backupToiCloud)")
    }

    public func keyWith(name: String) -> PrivateKey? {

        let keys = try? storedKeys()
        return keys?.first(where: {$0.name == name})
    }

    public func storedKeys() throws -> [PrivateKey] {
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        
        return try keysFromQuery(query: query)
    }

    private func keysFromQuery(query: [String: Any]) throws -> [PrivateKey]  {
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
    
    public func setActiveKey(_ name: KeyName?) throws {

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
            guard let firstStoredKey = try storedKeys().first else {
                throw KeyManagerError.notFound
            }
            try setActiveKey(firstStoredKey.name)
            return firstStoredKey
        }
        return try getKey(by: activeKeyName)
    }
    
    func getKey(by keyName: KeyName) throws -> PrivateKey {

        
        
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
        try setPasswordHash(hash: hashed)
    }

    public func setOrUpdatePassword(_ password: String) throws {
        let hashed = try hashFrom(password: password)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: hashed
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            try setPassword(password)
        } else {
            try checkStatus(status: status)
        }
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

    public func getPasswordHash() throws -> Data  {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        do {
            try checkStatus(status: status)
            guard let item = item, let passwordData = item as? Data else {
                throw KeyManagerError.notFound
            }
            return passwordData
        } catch let managerError as KeyManagerError {
            if case .notFound = managerError {
                throw KeyManagerError.invalidPassword
            } else {
                throw managerError
            }
        }
    }

    public func setPasswordHash(hash: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecValueData as String: hash,
        ]
        let setPasswordStatus = SecItemAdd(query as CFDictionary, nil)

        try checkStatus(status: setPasswordStatus)

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
            let passwordData = try getPasswordHash()
            guard let hashString = String(data: passwordData, encoding: .utf8) else {
                throw KeyManagerError.dataError
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

private extension KeychainManager {
    static func checkStatus(status: OSStatus, defaultError: KeyManagerError? = nil) throws {
        let throwDefault = defaultError ?? .unhandledError(determineOSStatus(status: status))
        switch status {
        case errSecItemNotFound:
            throw KeyManagerError.notFound
        case errSecDuplicateItem:
            throw KeyManagerError.keyExists
        case errSecSuccess:
            break
        default:
            throw throwDefault
        }
    }

    func checkStatus(status: OSStatus, defaultError: KeyManagerError? = nil) throws {
        try Self.checkStatus(status: status, defaultError: defaultError)
    }

    func queryForPassphrase(additionalQuery: [String: Any]? = nil) -> [String: Any] {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passPhraseKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        if let additionalQuery {

            return baseQuery.merging(additionalQuery, uniquingKeysWith: { $1 })
        }

        return baseQuery
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
}

private extension PrivateKey {

    
    var applicationLabel: String {
        "\(KeychainConstants.applicationTag).\(name)"
    }

    var keychainQueryDictForUpdate: [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: name.data(using: .utf8)!,
            kSecAttrCreationDate as String: creationDate,
        ]
    }

    var keychainQueryDictForKeychain: [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: name.data(using: .utf8)!,
            kSecAttrCreationDate as String: creationDate,
            kSecValueData as String: Data(keyBytes),
            kSecAttrApplicationLabel as String: applicationLabel,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
    }
}
