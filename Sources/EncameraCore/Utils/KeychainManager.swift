//
//  KeychainManager.swift
//  Encamera
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation
import Sodium
import Combine
import Security // Need this import for keychain constants

private enum KeychainConstants {
    static let applicationTag = "com.encamera.key"
    static let account = "encamera"
    static let minKeyLength = 2
    static let passPhraseKeyItem = "encamera_key_passphrase"
    static let passcodeTypeKeyItem = "encamera_passcode_type"
    static let backupStatusKeyItem = "com.encamera.backupStatus"
}

struct KeychainItem {
    let name: String
    let creationDate: Date
    let type: String
    let storageType: String
}

public struct KeyPassphrase: Codable {
    public let words: [String]
}


public class KeychainManager: ObservableObject, KeyManager, DebugPrintable {
    

    
    public var passcodeType: PasscodeType {
        if passwordExists() == false {
            return .none
        }

        // Try to retrieve stored passcode type from keychain
        if let storedPasscodeType = try? retrievePasscodeTypeFromKeychain(), passwordExists() {
            return storedPasscodeType
        }
        
        // If no passcode type is stored, set the default value
        let defaultPasscodeType = PasscodeType.pinCode(length: AppConstants.defaultPinCodeLength)
        try? savePasscodeTypeToKeychain(defaultPasscodeType)
        return defaultPasscodeType
    }


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

    // Renamed and reimplemented to read the central backup status flag
    public var isSyncEnabled: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Should be synced, but query defensively
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, let boolVal = data.boolValue {
            return boolVal
        } else {
            // Default to false if not found or error reading
            if status != errSecItemNotFound {
                 print("Error reading backup status flag: \\(determineOSStatus(status: status)). Defaulting to false.")
            }
            return false
        }
    }

    private var keySubject: PassthroughSubject<PrivateKey?, Never> = .init()
    
    required public init(isAuthenticated: AnyPublisher<Bool, Never>) {
        self.isAuthenticated = isAuthenticated
        self.isAuthenticated.sink { [weak self] newValue in
            do {
                try self?.getActiveKeyAndSet()
            } catch {
                self?.printDebug("Error getting/setting active key", error)
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
                kSecClass as String: keychainClass,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Match any existing item
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

        try? clearPassword()

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

        return try generateKeyFromPasswordComponentsAndSave(selectedWords, name: name)
    }

    @discardableResult public func saveKeyWithPassphrase(passphrase: KeyPassphrase) throws -> PrivateKey {
        
        return try generateKeyFromPasswordComponentsAndSave(passphrase.words, name: AppConstants.defaultKeyName)
    }

    @discardableResult public func generateKeyFromPasswordComponentsAndSave(_ components: [String], name: String) throws -> PrivateKey {
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
        
        try save(key: key, setNewKeyToCurrent: true)

        // Save or update the passphrase in the keychain
        let passphraseData = fullPassword.data(using: .utf8)!
        let passphraseQuery = queryForPassphrase(additionalQuery: [:])

        // Determine sync status from the central flag
        let shouldSync = self.isSyncEnabled

        var withOptions: [String: Any] = passphraseQuery
        withOptions[kSecReturnData as String] = true

        var item: CFTypeRef?
        let queryResult = SecItemCopyMatching(withOptions as CFDictionary, &item)

        switch queryResult {
        case errSecSuccess:
            // Passphrase exists, update it
            let updateQuery: [String: Any] = [
                kSecValueData as String: passphraseData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Use isSyncEnabled
            ]
            let updateStatus = SecItemUpdate(passphraseQuery as CFDictionary, updateQuery as CFDictionary)

            // We can ignore ItemNotFound errors here, as the passphrase might not exist
            if updateStatus != errSecItemNotFound {
                try checkStatus(status: updateStatus)
            }
        case errSecItemNotFound:
            // Passphrase does not exist, add it
            let addQuery = queryForPassphrase(additionalQuery: [
                kSecValueData as String: passphraseData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Use isSyncEnabled
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

        // Construct without the boolean flag
        let keyPassphrase = KeyPassphrase(words: words)

        return keyPassphrase
    }

    public func validateKeyName(name: String) throws {
        guard name.count > KeychainConstants.minKeyLength else {
            throw KeyManagerError.keyNameError
        }
    }
    
    public func save(key: PrivateKey, setNewKeyToCurrent: Bool) throws {
        // Use the central isSyncEnabled flag to determine sync status
        let shouldSync = self.isSyncEnabled
        var query = key.keychainQueryDictForKeychain
        query[kSecAttrSynchronizable as String] = shouldSync ? kCFBooleanTrue : kCFBooleanFalse

        if let existingKey = try? getKey(by: key.name) {
            let updateQuery: [String: Any] = [
                kSecValueData as String: Data(key.keyBytes),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Use isSyncEnabled
            ]
            // Use the base query from the existing key for update, but target by label/name
            let baseQuery = try updateKeyQuery(for: existingKey.name)
            let updateStatus = SecItemUpdate(baseQuery, updateQuery as CFDictionary)
            try checkStatus(status: updateStatus)

        } else {
            // Use the modified query with explicit sync status for adding
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            try checkStatus(status: addStatus)
        }

        if setNewKeyToCurrent {
            try setActiveKey(key.name)
        }
    }

    public func backupKeychainToiCloud(backupEnabled: Bool) throws {
        
        // --- Add/Update the centralized backup status flag ---
        let backupStatusQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem
        ]

        // Attributes for the backup status item
        // NOTE: kSecAttrSynchronizable is ALWAYS true for this item
        let backupStatusAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecValueData as String: backupEnabled.data, // Store the actual boolean value
            kSecAttrSynchronizable as String: kCFBooleanTrue!, // Always sync this flag itself
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked // Consistent accessibility
        ]
        
        // Try to add the item first
        var status = SecItemAdd(backupStatusAttributes as CFDictionary, nil)
        
        // If it already exists, update it
        if status == errSecDuplicateItem {
            let updateDict: [String: Any] = [
                kSecValueData as String: backupEnabled.data // Only update the value
                // kSecAttrSynchronizable is implicitly kept as true because we don't change it
                // kSecAttrAccessible should also remain as set initially
            ]
            status = SecItemUpdate(backupStatusQuery as CFDictionary, updateDict as CFDictionary)
        }
        
        // Check status after add or update attempt
        try checkStatus(status: status)
        
        // --- Update existing items based on backupEnabled ---
        let keys = try storedKeys()
        for key in keys {
            // Pass backupEnabled to update individual key sync status
            try update(key: key, backupToiCloud: backupEnabled)
        }
        
        // Update Passphrase sync status based on backupEnabled
        let updateQuery = [
            kSecAttrSynchronizable as String: backupEnabled ? kCFBooleanTrue! : kCFBooleanFalse as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked // Maintain accessibility
        ] as [String : Any]
        let updateStatus = SecItemUpdate(queryForPassphrase() as CFDictionary, updateQuery as CFDictionary)
        
        // We can ignore ItemNotFound errors here, as the passphrase might not exist
        if updateStatus != errSecItemNotFound {
            try checkStatus(status: updateStatus)
        }

        // Also update the PasscodeType item's synchronizable attribute based on backupEnabled
        let passcodeTypeUpdateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Ensure we find it regardless of sync status
        ]
        let passcodeTypeUpdateDict: [String: Any] = [
            kSecAttrSynchronizable as String: backupEnabled ? kCFBooleanTrue! : kCFBooleanFalse as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked // Keep it accessible
        ]
        let passcodeTypeUpdateStatus = SecItemUpdate(passcodeTypeUpdateQuery as CFDictionary, passcodeTypeUpdateDict as CFDictionary)
        // We can ignore ItemNotFound errors here, as the passcode type might not exist yet
        if passcodeTypeUpdateStatus != errSecItemNotFound {
            try checkStatus(status: passcodeTypeUpdateStatus)
        }

        // Also update the Password Hash item's synchronizable attribute based on backupEnabled
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Ensure we find it regardless of sync status
        ]
        let passwordUpdateDict: [String: Any] = [
            kSecAttrSynchronizable as String: backupEnabled ? kCFBooleanTrue! : kCFBooleanFalse as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked // Keep it accessible
        ]
        let passwordUpdateStatus = SecItemUpdate(passwordQuery as CFDictionary, passwordUpdateDict as CFDictionary)
        // We can ignore ItemNotFound errors here, as the password might not exist yet
        if passwordUpdateStatus != errSecItemNotFound {
            try checkStatus(status: passwordUpdateStatus)
        }

    }

    public func update(key: PrivateKey, backupToiCloud: Bool) throws {
        
        var updateDict: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        if backupToiCloud {
            updateDict[kSecAttrSynchronizable as String] = kCFBooleanTrue
        } else {
            updateDict[kSecAttrSynchronizable as String] = kCFBooleanFalse
        }
        let query = try updateKeyQuery(for: key.name)
        
        let status = SecItemUpdate(query, updateDict as CFDictionary)
        try checkStatus(status: status)
        printDebug("Key updated: \(key.name), iCloud: \(backupToiCloud)")
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
        
        // If no keys are found, return an empty array instead of throwing
        if status == errSecItemNotFound {
            return []
        }
        // For other non-success statuses, throw an error
        try checkStatus(status: status) 

        guard let keychainItems = item as? [[String: Any]] else {
            // This case might happen if status is success but item is nil or wrong type
            printDebug("Keychain query succeeded but failed to cast items.")
            return [] 
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
            kSecReturnAttributes as String: true, // Added to retrieve attributes
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        // Print details if successful
        if status == errSecSuccess, let existingItem = item as? [String: Any] {
            if let passwordData = existingItem[kSecValueData as String] as? Data,
               let passwordString = String(data: passwordData, encoding: .utf8) {
                printDebug("Retrieved Password Hash:", passwordString)
            } else {
                printDebug("Could not retrieve or decode password data.")
            }
            
            if let syncStatus = existingItem[kSecAttrSynchronizable as String] as? Bool {
                 printDebug("iCloud Sync Status:", syncStatus ? "Enabled" : "Disabled")
             } else {
                 // If kSecAttrSynchronizable is not present, it defaults to false (not synced)
                 // Sometimes kCFBooleanFalse might be returned as NSNumber 0
                 if let syncNum = existingItem[kSecAttrSynchronizable as String] as? NSNumber, syncNum.boolValue == false {
                     printDebug("iCloud Sync Status: Disabled (default or explicit)")
                 } else {
                     printDebug("Could not determine iCloud Sync Status or it's set to default (Disabled). Attribute value:", existingItem[kSecAttrSynchronizable as String] ?? "Not Present")
                 }
             }
        } else if status != errSecItemNotFound {
             printDebug("Keychain access error:", status)
         }

        do {
            try checkStatus(status: status)
        } catch is KeyManagerError {
            // Item not found is expected, don't log as an error here
             if status != errSecItemNotFound {
                 printDebug("KeyManagerError checking password existence:", status)
             }
        } catch {
            printDebug("Unexpected error checking password existence:", error)
        }
        
        // The function still returns true if an item was found, regardless of printing success
        return status == errSecSuccess
    }
    
    public func clearPassword() throws {
        // Query for the password hash item
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Ensure we find it regardless of sync status
        ]
        let passwordStatus = SecItemDelete(passwordQuery as CFDictionary)
        // Ignore item not found, throw on other errors
        if passwordStatus != errSecItemNotFound {
            try checkStatus(status: passwordStatus)
        }

        // Query for the passcode type item
        let passcodeTypeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Ensure we find it regardless of sync status
        ]
        let passcodeTypeStatus = SecItemDelete(passcodeTypeQuery as CFDictionary)
        // Ignore item not found, throw on other errors
        if passcodeTypeStatus != errSecItemNotFound {
            try checkStatus(status: passcodeTypeStatus)
        }
    }
    
    public func setPassword(_ password: String, type: PasscodeType) throws {
        let hashed = try hashFrom(password: password)
        try setPasswordHash(hash: hashed)
        try savePasscodeTypeToKeychain(type)
    }

    public func setOrUpdatePassword(_ password: String, type: PasscodeType) throws {
        let hashed = try hashFrom(password: password)
        let shouldSync = isSyncEnabled // Determine desired sync status

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Explicitly set sync status
        ]

        let update: [String: Any] = [
            kSecValueData as String: hashed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Explicitly set sync status
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            // Item doesn't exist, add it using setPassword which now handles sync status correctly
            try setPassword(password, type: type)
        } else {
            try checkStatus(status: status)
            // Also update passcode type, ensuring its sync status matches
            try savePasscodeTypeToKeychain(type)
        }
    }

    public func changePassword(newPassword: String, existingPassword: String, type: PasscodeType) throws {
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
            printDebug("Clearing password failed", error)
        }
        try setPassword(newPassword, type: type)
    }

    public func getPasswordHash() throws -> Data  {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
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
        let shouldSync = isSyncEnabled // Determine desired sync status

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecValueData as String: hash,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Explicitly set sync status
        ]
        let setPasswordStatus = SecItemAdd(query as CFDictionary, nil)

        // Handle potential duplicate item if update logic failed or wasn't called
        if setPasswordStatus == errSecDuplicateItem {
             let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: KeychainConstants.account,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Match any existing item to update
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: hash,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Explicitly set sync status
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            try checkStatus(status: updateStatus, defaultError: .keyUpdateFailed) // Throw specific error on update failure
        } else {
            try checkStatus(status: setPasswordStatus)
        }

    }

    public func checkPassword(_ password: String) throws -> Bool {

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
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
            printDebug("error checking password", error)
        }
        return false
    }
    
    // MARK: - Debugging

    public func dumpAllKeychainItems() {
        printDebug("--- Dumping All Keychain Items Accessible by App ---")

        let itemClasses: [CFString] = [
            kSecClassGenericPassword,
            kSecClassKey
            // Add other classes here if the app uses them (e.g., kSecClassCertificate)
        ]

        for itemClass in itemClasses {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]

            var items: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &items)

            printDebug("\n--- Querying Class: \(itemClass) ---")

            if status == errSecSuccess {
                guard let foundItems = items as? [[String: Any]] else {
                    printDebug("  Result found, but failed to cast to [[String: Any]] for class \(itemClass).")
                    continue
                }
                
                if foundItems.isEmpty {
                    printDebug("  No items found for this class.")
                } else {
                    printDebug("  Found \(foundItems.count) item(s):")
                    for (index, item) in foundItems.enumerated() {
                        printDebug("    --- Item \(index + 1) ---")
                        for (key, value) in item {
                            var printableValue: String = "<Non-printable or complex value>"
                            if let dataValue = value as? Data {
                                // Try decoding as UTF-8 string, otherwise show byte count
                                if let stringValue = String(data: dataValue, encoding: .utf8) {
                                    printableValue = "'\(stringValue)' (String, \(dataValue.count) bytes)"
                                } else {
                                    printableValue = "<Data: \(dataValue.count) bytes>"
                                }
                            } else if let dateValue = value as? Date {
                                printableValue = "\(dateValue) (Date)"
                            } else if let boolValue = value as? Bool {
                                printableValue = "\(boolValue) (Bool)"
                            } else if let numberValue = value as? NSNumber {
                                printableValue = "\(numberValue) (Number - Bool: \(numberValue.boolValue))" // Show Bool interpretation too
                            } else if let stringValue = value as? String {
                                printableValue = "'\(stringValue)' (String)"
                            } else {
                                // Fallback for other types
                                printableValue = "\(value) (Type: \(type(of: value)))"
                            }
                            
                            // Special handling for synchronizable status for clarity
                            if key == (kSecAttrSynchronizable as String) {
                                var syncStatusDesc = "Unknown/Not Present"
                                if let boolValue = value as? Bool {
                                    syncStatusDesc = boolValue ? "Enabled (Bool: true)" : "Disabled (Bool: false)"
                                } else if let numberValue = value as? NSNumber {
                                     syncStatusDesc = numberValue.boolValue ? "Enabled (Number: \(numberValue))" : "Disabled (Number: \(numberValue))"
                                 } else if value is NSNull {
                                      syncStatusDesc = "Disabled (NSNull)"
                                 }
                                 printDebug("      \(key): \(syncStatusDesc)")
                            } else {
                                printDebug("      \(key): \(printableValue)")
                            }
                        }
                    }
                }
            } else if status == errSecItemNotFound {
                printDebug("  No items found for this class (errSecItemNotFound).")
            } else {
                printDebug("  Error querying class \(itemClass): OSStatus \(status)")
            }
        }
        printDebug("--- End Keychain Dump ---")
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

    private func savePasscodeTypeToKeychain(_ passcodeType: PasscodeType) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(passcodeType)
        let shouldSync = isSyncEnabled

        // Base query to find the item, regardless of sync status
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Match any existing item
        ]

        // Attributes for adding the item
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Explicitly set sync status
        ]

        // Attributes for updating the item
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked, // Keep accessibility
            kSecAttrSynchronizable as String: shouldSync ? kCFBooleanTrue! : kCFBooleanFalse! // Explicitly set sync status
        ]

        // Try to update first
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            try checkStatus(status: addStatus)
        } else {
            // Check update status for errors other than not found
            try checkStatus(status: updateStatus)
        }
    }
    
    private func retrievePasscodeTypeFromKeychain() throws -> PasscodeType {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try checkStatus(status: status)
        
        guard let data = item as? Data else {
            throw KeyManagerError.dataError
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(PasscodeType.self, from: data)
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
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
    }
}

// Helper extension for Bool to Data conversion (if not already present)
extension Bool {
    var data: Data {
        var intValue = self ? 1 : 0
        return Data(bytes: &intValue, count: MemoryLayout<Int>.size)
    }
}

// Helper extension for Data to Bool conversion (needed for reading the flag later)
extension Data {
    var boolValue: Bool? {
        guard count == MemoryLayout<Int>.size else { return nil }
        return withUnsafeBytes { $0.load(as: Int.self) == 1 }
    }
}
