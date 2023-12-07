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
    case invalidInput
    case invalidSalt
    case keyDerivationFailed
    case dictionaryLoadError
    case dictionaryTooSmall

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
        case .invalidInput:
            return "Invalid input"
        case .invalidSalt:
            return "Invalid salt"
        case .keyDerivationFailed:
            return "Key derivation failed"
        case .dictionaryLoadError:
            return "Could not load dictionary"
        case .dictionaryTooSmall:
            return "Dictionary too small"
        }
    }
    
}

public protocol KeyManager {
    
    init(isAuthenticated: AnyPublisher<Bool, Never>)
    
    var isAuthenticated: AnyPublisher<Bool, Never> { get }
    var currentKey: PrivateKey? { get }
    var keyPublisher: AnyPublisher<PrivateKey?, Never> { get }
    func clearKeychainData()
    func keyWith(name: String) -> PrivateKey?
    func deleteKey(_ key: PrivateKey) throws
    func save(key: PrivateKey, setNewKeyToCurrent: Bool, backupToiCloud: Bool) throws
    func update(key: PrivateKey, backupToiCloud: Bool) throws
    func generateNewKey(name: String, backupToiCloud: Bool) throws -> PrivateKey
    func generateKeyUsingRandomWords(name: String) throws -> PrivateKey
    func retrieveKeyPassphrase() throws -> [String]
    func validateKeyName(name: String) throws
    func createBackupDocument() throws -> String
    func checkPassword(_ password: String) throws -> Bool
    func setPassword(_ password: String) throws
    func passwordExists() -> Bool
    func changePassword(newPassword: String, existingPassword: String) throws
}
