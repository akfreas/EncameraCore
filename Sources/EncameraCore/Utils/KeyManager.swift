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
    case keyUpdateFailed
    case keyDeletionFailed
    /// `backupKeychainToiCloud` could not put every credential item into the
    /// requested sync state. `actual` is the state the items were observed to
    /// be in afterwards, which is what the UI must show — never `attempted`.
    case syncFlipFailed(attempted: Bool, actual: Bool, details: String)
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
        case .keyUpdateFailed:
            return "Key update failed"
        case .keyDeletionFailed:
            return "Key deletion failed"
        case .syncFlipFailed:
            return L10n.Settings.MultiDeviceMode.flipFailed
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
             (.typeError, .typeError),
             (.keyUpdateFailed, .keyUpdateFailed),
             (.keyDeletionFailed, .keyDeletionFailed):
            return true
        case (.unhandledError(let lhsError), .unhandledError(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}


/// How far a key deletion reaches.
///
/// Deleting a `kSecAttrSynchronizable` item tombstones it and the deletion
/// propagates to every device on the iCloud account. That is almost never what
/// a user resetting *one* device expects, so account-wide is opt-in and callers
/// have to say so explicitly (ENC-72).
public enum KeyDeletionScope {
    /// Removes only this device's non-synchronizable copy. Other devices keep
    /// theirs, and a synced copy can flow back.
    case deviceLocal
    /// Removes the key everywhere on the account, synced copies included.
    case accountWide
}

public protocol KeyManager {
    
    init(isAuthenticated: AnyPublisher<Bool, Never>, keychainWrapper: KeychainWrapperProtocol)
    var isSyncEnabled: Bool { get }
    var isAuthenticated: AnyPublisher<Bool, Never> { get }
    var currentKey: PrivateKey? { get }
    var keyPublisher: AnyPublisher<PrivateKey?, Never> { get }
    var passcodeType: PasscodeType { get }
    /// Wipes this app's keychain footprint.
    ///
    /// There is deliberately no default value here: account-wide erasure is
    /// unrecoverable, so a caller has to name the scope it means. The no-argument
    /// `clearKeychainData()` convenience below resolves to `.deviceLocal`.
    func clearKeychainData(scope: KeyDeletionScope)
    /// Every Encamera-owned keychain item still readable from this device, across
    /// all item classes and INCLUDING iCloud-synced copies, as `"<class>|<name>"`.
    ///
    /// Exists so an erase can be verified rather than assumed. After an
    /// account-wide sweep this must be empty; anything left is residue the user was
    /// told had been destroyed.
    ///
    /// What this can and cannot prove about tombstones: Security.framework exposes
    /// no tombstone API, so the only local evidence available is that a
    /// widest-match query (`kSecAttrSynchronizableAny`) no longer returns the item.
    /// That the *deletion* replicated to the account's other devices can only be
    /// observed on another device — `TwoDeviceKeyErasureScopeDeviceTests` is where
    /// that claim is settled.
    func residualKeychainItemNames() -> [String]
    func keyWith(name: String) -> PrivateKey?
    @MainActor
    func keyWith(uuid: UUID) -> PrivateKey?
    func storedKeys() throws -> [PrivateKey]
    /// Removes a single key from the library, addressed by fingerprint.
    /// Defaults to device-local; see `KeyDeletionScope`.
    func deleteKey(fingerprint: String, scope: KeyDeletionScope) throws
    func getPasswordHash() throws -> Data
    func setPasswordHash(hash: Data) throws
    func save(key: PrivateKey, setNewKeyToCurrent: Bool) throws
    /// Derives the key a phrase encodes without writing anything to the keychain.
    /// Lets a caller inspect a candidate key's fingerprint before deciding to
    /// keep it — the fingerprint gate on additive key entry (ENC-99).
    func deriveKey(from components: [String], name: String) throws -> PrivateKey
    func generateKeyUsingRandomWords(name: String) throws -> PrivateKey
    @discardableResult func generateKeyFromPasswordComponentsAndSave(_ components: [String], name: String) throws -> PrivateKey
    @discardableResult func saveKeyWithPassphrase(passphrase: KeyPassphrase) throws -> PrivateKey
    @discardableResult func restoreDefaultKeyFromPassphraseIfNeeded() throws -> Bool
    func retrieveKeyPassphrase() throws -> KeyPassphrase
    func checkPassword(_ password: String) throws -> Bool
    func setPassword(_ password: String, type: PasscodeType) throws
    func setOrUpdatePassword(_ password: String, type: PasscodeType) throws
    func passwordExists() -> Bool
    func credentialSnapshot() -> KeychainCredentialSnapshot
    func changePassword(newPassword: String, existingPassword: String, type: PasscodeType) throws
    func backupKeychainToiCloud(backupEnabled: Bool) throws
    /// Turns Multi-Device Mode on, retaining every key this device already has.
    ///
    /// The only supported way to *enable* key sync. Unlike a bare
    /// `backupKeychainToiCloud(backupEnabled: true)` it guarantees that no key
    /// present before the flip is missing after it, and that the flip does not
    /// repoint which key this device writes new media with.
    func enableMultiDeviceMode() throws
    /// A different key already known to the iCloud account, or `nil` when this
    /// device's keys are the only ones the account knows about. Advisory: read
    /// from the last-writer-merges `MultiDeviceState` record, so it may be used
    /// to word a warning but never to decide anything destructive.
    func multiDeviceKeyConflict() -> MultiDeviceKeyConflict?
    func clearPassword() throws
    func dumpAllKeychainEntries() -> [KeychainDumpEntry]
    func getAuthenticationConfiguration() -> AuthenticationConfiguration?
    func setAuthenticationConfiguration(config: AuthenticationConfiguration) throws
    /// The always-synced multi-device state record; `nil` until some device writes it.
    func getMultiDeviceState() -> MultiDeviceState?
    /// Merges into the stored record rather than replacing it, so concurrent
    /// writers don't drop each other's device entries.
    func setMultiDeviceState(_ state: MultiDeviceState) throws
    /// Replaces the stored record WITHOUT the sticky-OR merge that
    /// `setMultiDeviceState` applies. The destructive delete-my-iCloud-data path
    /// (ENC-94) needs this to clear `hasUsedEncamera` and the fingerprints while
    /// carrying the existing device roster over — the merge can only ever set the
    /// marker, never clear it. This is an update, not a delete: the item stays
    /// synchronizable, so nothing is tombstoned. Use `setMultiDeviceState` for
    /// every additive write; this is only for the deliberate reset.
    ///
    /// Deliberately has NO protocol-extension default. The obvious one — forward to
    /// `setMultiDeviceState` — inverts this method's entire contract: the merge ORs
    /// `hasUsedEncamera` back to `true` and re-unions the fingerprints, so a
    /// conformer that didn't override got exactly the opposite of what its one
    /// caller needs, with no compiler error and no runtime signal (the destructive
    /// path calls it through this protocol behind a `try?`, so the no-op merge was
    /// completely invisible and the report still claimed success). A missing
    /// implementation must be a build failure.
    func overwriteMultiDeviceState(_ state: MultiDeviceState) throws
}

public extension KeyManager {
    /// Resets this device only. The safe default: nothing is tombstoned, so the
    /// user's other devices keep their keys, passphrase and password hash.
    func clearKeychainData() {
        clearKeychainData(scope: .deviceLocal)
    }

}
