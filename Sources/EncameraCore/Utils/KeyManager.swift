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
    case unhandledError(String)
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
    case typeError

    public var displayDescription: String {
        switch self {
        case .deleteKeychainItemsFailed:
            return L10n.couldNotDeleteKeychainItems
        case .unhandledError(let error):
            return "Unhandled error: \(error)"
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
        case .typeError:
            return "Type error"
        }

    }
    
}

extension KeyManagerError: Equatable {
    public static func ==(lhs: KeyManagerError, rhs: KeyManagerError) -> Bool {
        switch (lhs, rhs) {
        case (.deleteKeychainItemsFailed, .deleteKeychainItemsFailed),
             (.notAuthenticatedError, .notAuthenticatedError),
             (.keyNameError, .keyNameError),
             (.notFound, .notFound),
             (.dataError, .dataError),
             (.keyExists, .keyExists),
             (.invalidPassword, .invalidPassword),
             (.invalidInput, .invalidInput),
             (.invalidSalt, .invalidSalt),
             (.keyDerivationFailed, .keyDerivationFailed),
             (.dictionaryLoadError, .dictionaryLoadError),
             (.dictionaryTooSmall, .dictionaryTooSmall),
             (.typeError, .typeError):
            return true
        case (.unhandledError(let lhsError), .unhandledError(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}


public protocol KeyManager {
    
    init(isAuthenticated: AnyPublisher<Bool, Never>)
    
    var isAuthenticated: AnyPublisher<Bool, Never> { get }
    var currentKey: PrivateKey? { get }
    var keyPublisher: AnyPublisher<PrivateKey?, Never> { get }
    var areKeysStoredIniCloud: Bool { get }
    func clearKeychainData()
    func keyWith(name: String) -> PrivateKey?
    func storedKeys() throws -> [PrivateKey]
    func getPasswordHash() throws -> Data
    func setPasswordHash(hash: Data) throws
    func save(key: PrivateKey, setNewKeyToCurrent: Bool, backupToiCloud: Bool) throws
    func generateKeyUsingRandomWords(name: String) throws -> PrivateKey
    @discardableResult func generateKeyFromPasswordComponents(_ components: [String], name: String) throws -> PrivateKey
    @discardableResult func saveKeyWithPassphrase(passphrase: KeyPassphrase) throws -> PrivateKey
    func retrieveKeyPassphrase() throws -> KeyPassphrase
    func checkPassword(_ password: String) throws -> Bool
    func setPassword(_ password: String) throws
    func setOrUpdatePassword(_ password: String) throws
    func passwordExists() -> Bool
    func changePassword(newPassword: String, existingPassword: String) throws
    func backupKeychainToiCloud(backupEnabled: Bool) throws
    func clearPassword() throws
}
