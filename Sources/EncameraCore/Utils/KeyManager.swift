//
//  KeyManager.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Sodium
import Combine

public enum KeyManagerError: ErrorDescribable {
    case deleteKeychainItemsFailed
    case unhandledError
    case notAuthenticatedError
    case keyNameError
    case notFound
    case dataError
    case keyExists
    case invalidPassword
    
    public var displayDescription: String {
        switch self {
        case .deleteKeychainItemsFailed:
            return L10n.couldNotDeleteKeychainItems
        case .unhandledError:
            return L10n.unhandledError
        case .notAuthenticatedError:
            return L10n.notAuthenticatedForThisOperation
        case .keyNameError:
            return L10n.keyNameIsInvalidMustBeMoreThanTwoCharacters
        case .notFound:
            return L10n.keyNotFound
        case .dataError:
            return L10n.errorCodingKeychainData
        case .keyExists:
            return L10n.aKeyWithThisNameAlreadyExists
        case .invalidPassword:
            return L10n.invalidPassword
        }
    }
    
}

public protocol KeyManager {
    
    init(isAuthenticated: AnyPublisher<Bool, Never>, keyDirectoryStorage: DataStorageSetting)
    
    var isAuthenticated: AnyPublisher<Bool, Never> { get }
    var currentKey: PrivateKey? { get }
    var keyPublisher: AnyPublisher<PrivateKey?, Never> { get }
    var keyDirectoryStorage: DataStorageSetting { get }
    func clearKeychainData()
    func storedKeys() throws -> [PrivateKey]
    func deleteKey(_ key: PrivateKey) throws
    func setActiveKey(_ name: KeyName?) throws
    func save(key: PrivateKey, storageType: StorageType, setNewKeyToCurrent: Bool, backupToiCloud: Bool) throws
    func update(key: PrivateKey, backupToiCloud: Bool) throws
    func generateNewKey(name: String, storageType: StorageType, backupToiCloud: Bool) throws -> PrivateKey
    func validateKeyName(name: String) throws
    func createBackupDocument() throws -> String
    func checkPassword(_ password: String) throws -> Bool
    func setPassword(_ password: String) throws
    func passwordExists() -> Bool
    func changePassword(newPassword: String, existingPassword: String) throws
}
