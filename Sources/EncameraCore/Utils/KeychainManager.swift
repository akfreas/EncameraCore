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
import UIKit // For UIApplication state checking

private enum KeychainConstants {
    static let applicationTag = "com.encamera.key"
    static let account = "encamera"
    static let minKeyLength = 2
    static let passPhraseKeyItem = "encamera_key_passphrase"
    static let passcodeTypeKeyItem = "encamera_passcode_type"
    static let backupStatusKeyItem = "com.encamera.backupStatus"
    static let authenticationConfiguration = "com.encamera.authenticationConfiguration"
    static let multiDeviceState = "com.encamera.multiDeviceState"
}

struct KeychainItem {
    let name: String
    let creationDate: Date
    let type: String
    let storageType: String
}

// `KeychainDumpAttribute` / `KeychainDumpEntry` live in KeychainManagerDump.swift,
// which #200 split out of this file after #201 branched.

public struct KeyPassphrase: Codable {
    public let words: [String]

    public init(words: [String]) {
        self.words = words
    }
}


/// State of the central iCloud-backup flag item (account `com.encamera.backupStatus`).
/// `.notSet` means the flag item hasn't been written on this device yet — or, on a
/// fresh second device, hasn't arrived via iCloud Keychain yet.
public enum KeychainBackupFlagState {
    case enabled, disabled, notSet
}

/// Payload of the central iCloud-backup flag item, recording which device
/// flipped the switch and when. The item itself is always synchronizable, so
/// this object propagates to all devices — a second device that finds its key
/// material deleted can tell the user where the flip came from.
///
/// Metadata fields are nil for items migrated from the legacy boolean format,
/// where the flipping device was never recorded.
public struct KeychainBackupStatus: Codable, Equatable {
    public let enabled: Bool
    public let deviceID: String?
    public let deviceName: String?
    public let timestamp: Date?

    public init(enabled: Bool, deviceID: String?, deviceName: String?, timestamp: Date?) {
        self.enabled = enabled
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.timestamp = timestamp
    }

    /// True when the flip was recorded by a device other than this one.
    public var flippedByOtherDevice: Bool {
        guard let deviceID else { return false }
        return deviceID != DeviceIDProvider.deviceID()
    }
}

/// Point-in-time view of which credential items are present in the keychain,
/// queried with kSecAttrSynchronizableAny so items that arrived via iCloud
/// Keychain are counted regardless of the local backup-flag state. Used to
/// poll for iCloud Keychain arrival on a fresh install — there is no system
/// notification for it.
public struct KeychainCredentialSnapshot: Equatable {
    public let passwordExists: Bool
    public let passphraseExists: Bool
    public let defaultKeyExists: Bool
    public let backupFlagState: KeychainBackupFlagState
    /// Full flag payload with flip metadata; nil when the item is absent.
    public let backupStatus: KeychainBackupStatus?

    public init(passwordExists: Bool, passphraseExists: Bool, defaultKeyExists: Bool, backupFlagState: KeychainBackupFlagState, backupStatus: KeychainBackupStatus? = nil) {
        self.passwordExists = passwordExists
        self.passphraseExists = passphraseExists
        self.defaultKeyExists = defaultKeyExists
        self.backupFlagState = backupFlagState
        self.backupStatus = backupStatus
    }

    public var hasAnyCredential: Bool {
        passwordExists || passphraseExists || defaultKeyExists
    }
}

extension KeychainCredentialSnapshot: CustomStringConvertible {
    public var description: String {
        "[password=\(passwordExists), passphrase=\(passphraseExists), defaultKey=\(defaultKeyExists), backupFlag=\(backupFlagState)]"
    }
}

public class KeychainManager: ObservableObject, @preconcurrency KeyManager, DebugPrintable {



    private enum BackupFlagState {
        case enabled, disabled, notSet
    }

    public var backupFlagState: KeychainBackupFlagState {
        switch getBackupFlagState() {
        case .enabled: return .enabled
        case .disabled: return .disabled
        case .notSet: return .notSet
        }
    }

    /// Full payload of the backup status item, including which device flipped
    /// the switch and when. Nil when the item is absent or undecodable;
    /// metadata fields are nil for legacy boolean payloads.
    public var backupStatus: KeychainBackupStatus? {
        getBackupStatus()
    }

    // MARK: - Credential conflict handling

    /// Which credential set this device uses when a local (this device) and a
    /// synced (another device) copy of the same item coexist with different
    /// values — the aftermath of onboarding on a second device before iCloud
    /// Keychain delivered the first device's credentials.
    public enum CredentialConflictResolution: String {
        case preferLocal
        case preferSynced
    }

    public var conflictResolution: CredentialConflictResolution? {
        guard let raw = UserDefaultUtils.string(forKey: .credentialConflictResolution) else {
            return nil
        }
        return CredentialConflictResolution(rawValue: raw)
    }

    public func setConflictResolution(_ resolution: CredentialConflictResolution?) {
        printDebug("setConflictResolution(\(resolution?.rawValue ?? "nil")) — was \(conflictResolution?.rawValue ?? "nil")")
        if let resolution {
            UserDefaultUtils.set(resolution.rawValue, forKey: .credentialConflictResolution)
        } else {
            UserDefaultUtils.removeObject(forKey: .credentialConflictResolution)
        }
    }

    /// Returns the accounts (or the default key name) whose local and synced
    /// keychain items coexist with differing values. Empty when there is no
    /// conflict. Never deletes or modifies anything.
    public func detectCredentialConflicts() -> [String] {
        var conflicts: [String] = []

        let accounts = [
            KeychainConstants.account,
            KeychainConstants.passPhraseKeyItem,
            KeychainConstants.passcodeTypeKeyItem
        ]
        for account in accounts {
            let local = genericPasswordData(account: account, synchronizable: false)
            let synced = genericPasswordData(account: account, synchronizable: true)
            printDebug("conflict check '\(account)': local=\(local != nil ? "\(local!.count) bytes" : "absent"), synced=\(synced != nil ? "\(synced!.count) bytes" : "absent"), equal=\(local == synced)")
            if let local, let synced, local != synced {
                conflicts.append(account)
            }
        }

        // storedKeys() matches synchronizableAny, so a coexisting local and
        // synced default key shows up as two entries. Compare keyBytes rather
        // than raw item data: a key re-derived from the same passphrase gets a
        // fresh UUID in its stored blob but is NOT a conflict.
        let defaultKeyVariants = ((try? storedKeys()) ?? []).filter { $0.name == AppConstants.defaultKeyName }
        let distinctKeyBytes = Set(defaultKeyVariants.map { $0.keyBytes }).count
        printDebug("conflict check default key: \(defaultKeyVariants.count) variant(s), \(distinctKeyBytes) distinct keyBytes")
        if defaultKeyVariants.count > 1, distinctKeyBytes > 1 {
            conflicts.append(AppConstants.defaultKeyName)
        }

        printDebug("detectCredentialConflicts result: \(conflicts.isEmpty ? "none" : conflicts.joined(separator: ", "))")
        return conflicts
    }

    /// Fetches one specific variant (local or synced) of a generic-password
    /// item. All other reads in this class match either synchronizableAny or
    /// the flag-driven value, which can't distinguish coexisting variants.
    private func genericPasswordData(account: String, synchronizable: Bool) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        ]
        var item: CFTypeRef?
        guard keychainWrapper.secItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    public func credentialSnapshot() -> KeychainCredentialSnapshot {
        if !didLogVariantDetail {
            didLogVariantDetail = true
            logCredentialVariantState(context: "first credentialSnapshot")
        }

        let status = getBackupStatus()
        let flagState: KeychainBackupFlagState = status.map { $0.enabled ? .enabled : .disabled } ?? .notSet
        let snapshot = KeychainCredentialSnapshot(
            passwordExists: passwordExists(),
            passphraseExists: keyPassphraseExists(),
            defaultKeyExists: keyWith(name: AppConstants.defaultKeyName) != nil,
            backupFlagState: flagState,
            backupStatus: status
        )
        printDebug("credentialSnapshot: \(snapshot)")
        return snapshot
    }

    private var didLogVariantDetail = false

    /// Logs, for every credential account and key, whether a local and/or a
    /// synced variant exists. This is the view that distinguishes "item never
    /// marked synchronizable on the source device" from "item hasn't arrived
    /// here yet" — run it on BOTH devices when diagnosing sync.
    public func logCredentialVariantState(context: String) {
        let accounts = [
            KeychainConstants.account,
            KeychainConstants.passPhraseKeyItem,
            KeychainConstants.passcodeTypeKeyItem,
            KeychainConstants.backupStatusKeyItem
        ]
        for account in accounts {
            let local = genericPasswordData(account: account, synchronizable: false) != nil
            let synced = genericPasswordData(account: account, synchronizable: true) != nil
            printDebug("variant state (\(context)) '\(account)': local=\(local), synced=\(synced)")
        }
        let keys = (try? storedKeys()) ?? []
        if keys.isEmpty {
            printDebug("variant state (\(context)) keys: none")
        } else {
            let describedKeys = keys.map { "\($0.name)(synced=\($0.savedToiCloud))" }.joined(separator: ", ")
            printDebug("variant state (\(context)) keys: \(describedKeys)")
        }
    }

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
    let keychainWrapper: KeychainWrapperProtocol

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
        // Check the explicit flag state first
        switch getBackupFlagState() {
        case .enabled: return true
        case .disabled: return false
        case .notSet:
            // Fallback logic if the flag is not set (e.g., first run after update,
            // or a second device where the flag item hasn't synced yet).
            //
            // The key library is the strongest evidence available, so it is
            // consulted first and, when it exists, it decides. The answer is
            // `observedKeySyncState()` — *every* key synchronizable, not merely
            // one — which is the same definition the partial-failure path in
            // `backupKeychainToiCloud` reports as `actual` (ENC-86). Answering
            // "yes" off a single synced key would let a half-flipped library
            // (some keys synced, some local — now reachable, since ENC-69 lets
            // keys coexist) read as fully enabled, and the two definitions would
            // then disagree about the very same keychain. The conservative
            // reading is also the safe one for writes: a new key is born local
            // rather than being assumed synced by a sync that did not happen,
            // and a local key is recoverable where a wrongly-synced one is a
            // credential the user did not ask to put on the account.
            if let observed = observedKeySyncState() {
                printDebug("isSyncEnabled: flag notSet, key library observed sync state → \(observed)")
                return observed
            }

            // The backup-flag account itself is excluded: that item is always
            // written synchronizable and would make this check unconditionally true.
            let credentialAccounts = [
                KeychainConstants.account,
                KeychainConstants.passPhraseKeyItem,
                KeychainConstants.passcodeTypeKeyItem
            ]
            if let matched = credentialAccounts.first(where: { genericPasswordData(account: $0, synchronizable: true) != nil }) {
                printDebug("isSyncEnabled: flag notSet, but synchronizable '\(matched)' item exists → true")
                return true
            }
            printDebug("isSyncEnabled: flag notSet and no synchronizable credential items → false (writes will be local-only)")
            return false
        }
    }

    private var keySubject: PassthroughSubject<PrivateKey?, Never> = .init()

    public required init(isAuthenticated: AnyPublisher<Bool, Never>, keychainWrapper: KeychainWrapperProtocol = KeychainWrapper()) {
        self.isAuthenticated = isAuthenticated
        self.keychainWrapper = keychainWrapper
        self.isAuthenticated.sink { [weak self] newValue in
            guard let self = self, newValue == true else { return }
            do {
                try self.getActiveKeyAndSet()
            } catch {
                self.printDebug("Error during initial key setup (migration/load):", error)
                self.attemptKeyRestoreAfterFailedLoad()
            }
        }.store(in: &cancellables)
    }

    /// Heals key state after authentication when the active key can't be loaded.
    /// On a second device, the KVS-synced `currentKey` default may name a key
    /// that never reached this device, and the default key itself may still be
    /// derivable from the synced passphrase even if its keychain item hasn't
    /// arrived. Runs on every unlock, so key material that syncs in minutes
    /// after first launch is picked up on the next authentication.
    private func attemptKeyRestoreAfterFailedLoad() {
        printDebug("attemptKeyRestoreAfterFailedLoad: snapshot \(credentialSnapshot()), currentKey default='\(UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String ?? "nil")'")
        if let activeKeyName = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String,
           (try? getKey(by: activeKeyName)) == nil {
            printDebug("Clearing stale currentKey '\(activeKeyName)' — key not present on this device")
            UserDefaultUtils.removeObject(forKey: UserDefaultKey.currentKey)
        }

        do {
            let restored = try restoreDefaultKeyFromPassphraseIfNeeded()
            try getActiveKeyAndSet()
            printDebug("attemptKeyRestoreAfterFailedLoad: succeeded (restoredFromPassphrase=\(restored), currentKey='\(currentKey?.name ?? "nil")')")
        } catch {
            printDebug("Key restore after failed load did not succeed:", error)
        }
    }

    /// Wipes this app's keychain footprint at the requested scope.
    ///
    /// `.deviceLocal` matches only `kSecAttrSynchronizable: false` items, so no
    /// deletion tombstone is created and the account's other devices keep their
    /// key, passphrase and password hash. `.accountWide` restores the historical
    /// `kSecAttrSynchronizableAny` sweep, which removes the credentials from
    /// every device on the iCloud account and cannot be undone.
    ///
    /// Known consequence of the device-local scope: when iCloud key backup is on,
    /// this device's copies of the key and passphrase *are* the synced items, so
    /// they survive a device-local reset. The keychain offers no way to drop a
    /// local copy of a synchronizable item without tombstoning it everywhere;
    /// removing them here would be exactly the account nuke this split exists to
    /// prevent. Turning backup off (or removing the device from iCloud) is the
    /// supported way to clear those.
    ///
    /// That consequence is why `ErasureScope.allData` resolves to `.accountWide`:
    /// with Multi-Device Mode on, every item is synchronizable, so a device-local
    /// sweep from "Erase All Data" matched nothing and left the key and passcode
    /// fully intact on a screen that promised to remove them. `.deviceLocal`
    /// remains correct for `.appData` and for any caller whose user still owns
    /// another device — it is a real guarantee, just not the one that screen makes.
    public func clearKeychainData(scope: KeyDeletionScope) {
        // The sync predicate every query below shares. Everything about the
        // blast radius of this function follows from this one value.
        let syncMatch: Any
        switch scope {
        case .deviceLocal:
            syncMatch = kCFBooleanFalse!
        case .accountWide:
            syncMatch = kSecAttrSynchronizableAny
        }

        let keychainClasses: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]

        // This sweep intentionally catches `DeviceIDProvider`'s item (service
        // `com.encamera.device`), which is non-synchronizable and belongs to this
        // device — it should not outlive a device-local reset. It intentionally
        // does NOT catch `com.encamera.multiDeviceState`, which is hardcoded
        // synchronizable and is account state, not device state; it dies only
        // under `.accountWide`.
        for keychainClass in keychainClasses {
            let query: [String: Any] = [
                kSecClass as String: keychainClass,
                kSecAttrSynchronizable as String: syncMatch
            ]

            let status = keychainWrapper.secItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                print("Failed to delete items for class \(keychainClass): \(status)")
            }
        }

        let passphraseQuery = queryForPassphrase(additionalQuery: [
            kSecAttrSynchronizable as String: syncMatch
        ])
        let passphraseStatus = keychainWrapper.secItemDelete(passphraseQuery as CFDictionary)
        if passphraseStatus != errSecSuccess && passphraseStatus != errSecItemNotFound {
            print("Failed to delete passphrase item: \(passphraseStatus)")
        }

        // The backup status flag and the authentication configuration are both
        // hardcoded-synchronizable account state. Only an account-wide erase may
        // remove them; deleting them on a device-local reset would tell every
        // other device that backup was never enabled and that no passcode is set.
        switch scope {
        case .deviceLocal:
            // Delete only this device's password hash and legacy passcode-type
            // items, and leave the synced authentication configuration alone.
            try? clearLocalPasswordItems()
        case .accountWide:
            let backupStatusQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            let backupStatusDeleteStatus = keychainWrapper.secItemDelete(backupStatusQuery as CFDictionary)
            if backupStatusDeleteStatus != errSecSuccess && backupStatusDeleteStatus != errSecItemNotFound {
                print("Failed to delete backup status flag item: \(backupStatusDeleteStatus)")
            }

            // `com.encamera.multiDeviceState` is written with a hardcoded
            // `kSecAttrSynchronizable: true`, and a query pinned to
            // `kSecAttrSynchronizableAny` in the class sweep above does NOT reliably
            // match an item written that way — so it survived what was supposed to be
            // a total erase and told the next install "this account has used
            // Encamera". Deleted explicitly, by account, for the same reason the
            // backup flag is.
            let multiDeviceStateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: KeychainConstants.multiDeviceState,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            let multiDeviceStateDeleteStatus = keychainWrapper.secItemDelete(multiDeviceStateQuery as CFDictionary)
            if multiDeviceStateDeleteStatus != errSecSuccess && multiDeviceStateDeleteStatus != errSecItemNotFound {
                print("Failed to delete multi-device state item: \(multiDeviceStateDeleteStatus)")
            }

            try? clearPassword()
        }

        try? setActiveKey(nil)
        print("Keychain data cleared (scope: \(scope))")
    }

    /// See `KeyManager.residualKeychainItemNames()`. Queries the same five classes
    /// the sweep does, with the same widest-match sync predicate, so a survivor the
    /// sweep should have taken cannot hide from the check that follows it.
    public func residualKeychainItemNames() -> [String] {
        let classes: [(secClass: CFString, name: String)] = [
            (kSecClassGenericPassword, "GenericPassword"),
            (kSecClassInternetPassword, "InternetPassword"),
            (kSecClassCertificate, "Certificate"),
            (kSecClassKey, "Key"),
            (kSecClassIdentity, "Identity")
        ]

        var names: [String] = []
        for entry in classes {
            let query: [String: Any] = [
                kSecClass as String: entry.secClass,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            var result: CFTypeRef?
            guard keychainWrapper.secItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[String: Any]] else { continue }
            for item in items {
                // Whichever attribute names the item for this class: generic
                // passwords carry an account, key items a label or application tag.
                let name = (item[kSecAttrAccount as String] as? String)
                    ?? (item[kSecAttrLabel as String] as? String)
                    ?? (item[kSecAttrService as String] as? String)
                    ?? (item[kSecAttrApplicationTag as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    ?? "<unnamed>"
                names.append("\(entry.name)|\(name)")
            }
        }
        return names.sorted()
    }

    /// Removes only this device's non-synchronizable password hash and legacy
    /// passcode-type items. Unlike `clearPassword()` it does not rewrite the
    /// always-synced `AuthenticationConfiguration`, because that write would
    /// propagate to every device on the account.
    private func clearLocalPasswordItems() throws {
        let accounts = [KeychainConstants.account, KeychainConstants.passcodeTypeKeyItem]
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kCFBooleanFalse!
            ]
            let status = keychainWrapper.secItemDelete(query as CFDictionary)
            if status != errSecItemNotFound {
                try checkStatus(status: status)
            }
        }
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

    /// Derives a key from passphrase components without writing anything to the
    /// keychain. Words 1-4 are the salt, the rest the password input to pwHash.
    ///
    /// Public since ENC-99: the additive missing-key entry has to know a phrase's
    /// fingerprint *before* deciding whether to accept it, so deriving and saving
    /// can no longer be the same step.
    public func deriveKey(from components: [String], name: String) throws -> PrivateKey {
        guard !components.isEmpty else {
            throw KeyManagerError.invalidInput
        }

        try validateKeyName(name: name)
        let splitIndex = 4
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

        return PrivateKey(name: name, keyBytes: keyBytes, creationDate: Date())
    }

    /// Re-derives the default key from an already-present passphrase item.
    /// Exists for the second-device case where iCloud Keychain has delivered the
    /// password/passphrase items but the key item hasn't arrived (or was written
    /// non-synchronizable on the old device). Never writes the passphrase item,
    /// so a synced passphrase can't be overwritten or flipped local-only here.
    @discardableResult public func restoreDefaultKeyFromPassphraseIfNeeded() throws -> Bool {
        guard passwordExists() else {
            printDebug("restore: skipping — no password hash present")
            return false
        }
        guard keyWith(name: AppConstants.defaultKeyName) == nil else {
            printDebug("restore: skipping — default key already present")
            return false
        }
        guard let passphrase = try? retrieveKeyPassphrase() else {
            printDebug("restore: skipping — passphrase item not retrievable")
            return false
        }

        printDebug("restore: password present, default key absent, passphrase has \(passphrase.words.count) words — deriving key")
        let key = try deriveKey(from: passphrase.words, name: AppConstants.defaultKeyName)
        try save(key: key, setNewKeyToCurrent: true)
        printDebug("restore: default key re-derived and saved as current (isSyncEnabled=\(isSyncEnabled))")
        return true
    }

    @discardableResult public func generateKeyFromPasswordComponentsAndSave(_ components: [String], name: String) throws -> PrivateKey {
        let key = try deriveKey(from: components, name: name)
        let fullPassword = components.joined(separator: "-")

        do {
            try save(key: key, setNewKeyToCurrent: true)
        } catch {
            self.printDebug("Could not save key", error)
            throw error
        }

        // Save or update the passphrase in the keychain
        let passphraseData = fullPassword.data(using: .utf8)!
        let passphraseQuery = queryForPassphrase(additionalQuery: [:])

        var withOptions: [String: Any] = passphraseQuery
        withOptions[kSecReturnData as String] = true

        var item: CFTypeRef?
        let queryResult = keychainWrapper.secItemCopyMatching(withOptions as CFDictionary, &item)

        switch queryResult {
        case errSecSuccess:
            // Passphrase exists, update it
            let updateQuery: [String: Any] = [
                kSecValueData as String: passphraseData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncValueForWrites,
            ]
            let updateStatus = keychainWrapper.secItemUpdate(passphraseQuery as CFDictionary, updateQuery as CFDictionary)

            // We can ignore ItemNotFound errors here, as the passphrase might not exist
            if updateStatus != errSecItemNotFound {
                try checkStatus(status: updateStatus)
            }
        case errSecItemNotFound:
            // Passphrase does not exist, add it
            let addQuery = queryForPassphrase(additionalQuery: [
                kSecValueData as String: passphraseData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncValueForWrites // Use helper
            ])
            let addStatus = keychainWrapper.secItemAdd(addQuery as CFDictionary, nil)
            try checkStatus(status: addStatus)
        default:
            // Handle other errors
            try checkStatus(status: queryResult)
        }


        return key

    }

    public func retrieveKeyPassphrase() throws -> KeyPassphrase {
        var additionalQuery: [String: Any] = [
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,  // Include attributes in the result
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // While a conflict resolution is active, pin the read to the chosen
        // credential set — with both a local and a synced passphrase present,
        // the default synchronizableAny match is nondeterministic.
        switch conflictResolution {
        case .preferLocal:
            additionalQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        case .preferSynced:
            additionalQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        case nil:
            break
        }
        let query: [String: Any] = queryForPassphrase(additionalQuery: additionalQuery)

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
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
        var query = key.keychainQueryDictForKeychain
        query[kSecAttrSynchronizable as String] = syncValueForWrites // Use helper

        // Dedupe on key material, not on the display name. Two keys both named
        // `encamera_default_key` are two different keys and must coexist; the
        // same key bytes saved twice are one item. Probing by name here is what
        // silently overwrote an existing key on import.
        if let baseQuery = existingKeyItemQuery(for: key) {
            // Deliberately does NOT write kSecAttrCreationDate: storedKeys()
            // sorts by it, so refreshing it on every save reorders the library.
            // Writing the identity attributes here also relabels a legacy item
            // in place, without a delete.
            var updateQuery: [String: Any] = [
                kSecValueData as String: key.keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncValueForWrites, // Use helper
            ]
            updateQuery.merge(key.keychainIdentityAttributes) { current, _ in current }
            let updateStatus = keychainWrapper.secItemUpdate(baseQuery as CFDictionary, updateQuery as CFDictionary)
            try checkStatus(status: updateStatus)

        } else {
            // Use the modified query with explicit sync status for adding
            let addStatus = keychainWrapper.secItemAdd(query as CFDictionary, nil)
            try checkStatus(status: addStatus)
        }

        if setNewKeyToCurrent {
            try setActiveKey(key)
        }
    }

    public func getAuthenticationConfiguration() -> AuthenticationConfiguration? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.authenticationConfiguration,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Find it regardless of its internal sync status
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                printDebug("getAuthenticationConfiguration: query failed with status \(status) (\(determineOSStatus(status: status)))")
            }
            return nil
        }

        guard let data = item as? Data,
              let config = try? JSONDecoder().decode(AuthenticationConfiguration.self, from: data) else {
            printDebug("getAuthenticationConfiguration: Could not decode authentication configuration")
            return nil
        }

        return config
    }

    public func setAuthenticationConfiguration(config: AuthenticationConfiguration) throws {

        guard let encoded = try? JSONEncoder().encode(config) else {
            printDebug("setAuthenticationConfiguration: Could not encode authentication configuration")
            throw KeyManagerError.dataError
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.authenticationConfiguration,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        // NOTE: kSecAttrSynchronizable is ALWAYS true for this item
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.authenticationConfiguration,
            kSecValueData as String: encoded,
            kSecAttrSynchronizable as String: kCFBooleanTrue!, // Always sync this item itself
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked // Consistent accessibility
        ]

        // Try to add the item first; if it already exists, update it in place
        var status = keychainWrapper.secItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let newAttributes: [String: Any] = [
                kSecValueData as String: encoded
            ]
            status = keychainWrapper.secItemUpdate(updateQuery as CFDictionary, newAttributes as CFDictionary)
        }

        try checkStatus(status: status)

        printDebug("setAuthenticationConfiguration: Authentication configuration set successfully")
    }

    /// Reads the always-synced multi-device state record. `nil` means no device
    /// on this account has written it yet (or it hasn't arrived from iCloud).
    ///
    /// Queried with `kSecAttrSynchronizableAny` so it is found regardless of the
    /// stored item's sync flag, matching `getAuthenticationConfiguration`.
    public func getMultiDeviceState() -> MultiDeviceState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.multiDeviceState,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                printDebug("getMultiDeviceState: query failed with status \(status) (\(determineOSStatus(status: status)))")
            }
            return nil
        }

        guard let data = item as? Data,
              let state = try? JSONDecoder().decode(MultiDeviceState.self, from: data) else {
            printDebug("getMultiDeviceState: Could not decode multi-device state")
            return nil
        }

        return state
    }

    /// Merges `state` into the stored multi-device state record and writes it back.
    ///
    /// Merging rather than replacing means a device appending itself to the
    /// roster can't drop another device that appeared since it last read.
    /// See `MultiDeviceState.merging(existing:incoming:)`.
    public func setMultiDeviceState(_ state: MultiDeviceState) throws {
        let merged = MultiDeviceState.merging(existing: getMultiDeviceState(), incoming: state)
        try writeMultiDeviceStateRecord(merged)
    }

    /// Replaces the record with exactly `state`, bypassing the sticky-OR merge, so
    /// the destructive path (ENC-94) can clear `hasUsedEncamera` and the
    /// fingerprints while keeping the roster the caller carried over. Still an
    /// update (never a delete), so the synchronizable item is not tombstoned.
    public func overwriteMultiDeviceState(_ state: MultiDeviceState) throws {
        try writeMultiDeviceStateRecord(state)
    }

    /// The raw synchronizable write shared by the merging setter and the
    /// non-merging overwrite. Adds the item, or updates its value data in place if
    /// it already exists — never deletes it, so no cross-device tombstone.
    private func writeMultiDeviceStateRecord(_ state: MultiDeviceState) throws {
        guard let encoded = try? JSONEncoder().encode(state) else {
            printDebug("setMultiDeviceState: Could not encode multi-device state")
            throw KeyManagerError.dataError
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.multiDeviceState,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        // NOTE: kSecAttrSynchronizable is ALWAYS true for this item — it must
        // reach every device on the account regardless of the backup toggle.
        // That is why nothing secret may ever enter MultiDeviceState.
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.multiDeviceState,
            kSecValueData as String: encoded,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        var status = keychainWrapper.secItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let newAttributes: [String: Any] = [
                kSecValueData as String: encoded
            ]
            status = keychainWrapper.secItemUpdate(updateQuery as CFDictionary, newAttributes as CFDictionary)
        }

        try checkStatus(status: status)

        printDebug("setMultiDeviceState: Multi-device state set successfully")
    }

    /// Writes the always-synced central backup status flag. Extracted so the
    /// partial-failure path can rewrite it with the state the keychain items are
    /// *actually* in, rather than leaving it asserting the attempted state.
    private func writeBackupFlag(enabled backupEnabled: Bool) throws {
        let backupStatusQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        // Record which device flipped the switch: this payload syncs, so a
        // second device whose key material gets deleted by the flip can tell
        // the user where the flip came from.
        let statusPayload = try Self.encodeBackupStatus(KeychainBackupStatus(
            enabled: backupEnabled,
            deviceID: DeviceIDProvider.deviceID(),
            deviceName: DeviceIDProvider.deviceName(),
            timestamp: Date()
        ))

        // Attributes for the backup status item
        // NOTE: kSecAttrSynchronizable is ALWAYS true for this item
        let backupStatusAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecValueData as String: statusPayload,
            kSecAttrSynchronizable as String: kCFBooleanTrue!, // Always sync this flag itself
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked // Consistent accessibility
        ]

        // Try to add the item first
        var status = keychainWrapper.secItemAdd(backupStatusAttributes as CFDictionary, nil)

        // If it already exists, update it
        if status == errSecDuplicateItem {
            let newAttributes: [String: Any] = [
                kSecValueData as String: statusPayload,
            ]
            status = keychainWrapper.secItemUpdate(backupStatusQuery as CFDictionary, newAttributes as CFDictionary)
        }

        // Check status after add or update attempt
        printDebug("flip: backup flag write status \(status) (\(determineOSStatus(status: status)))")
        try checkStatus(status: status)
    }

    /// The sync state the stored key items are observably in, independent of
    /// what the flag claims. `true` only when every key item is synchronizable,
    /// so a half-flipped library reads as "not enabled" — the conservative
    /// answer, since it makes subsequent writes stay local rather than assume a
    /// sync that did not happen. `nil` when there are no keys to judge by.
    ///
    /// Judged on the raw `kSecClassKey` items rather than on `storedKeys()`
    /// (ENC-98): a key item that fails to decode — a corrupt or not-yet-migrated
    /// blob — is still a key sitting in the keychain in some sync scope, and a
    /// local one of those means the library is not fully synced. Decoding first
    /// would make it invisible and report the library as clean.
    ///
    /// `isSyncEnabled` calls this on its `.notSet` path, so nothing this touches
    /// may consult `syncValueForWrites`, or the loop closes into unbounded
    /// recursion. Querying `SecItem` directly keeps that guaranteed.
    private func observedKeySyncState() -> Bool? {
        // Scoped to Encamera's own key items by `kSecAttrApplicationTag`, which
        // `PrivateKey.keychainIdentityAttributes` writes as
        // `"\(KeychainConstants.applicationTag).\(name)"`. The tag can't be matched
        // server-side by prefix, so the items are enumerated and filtered here.
        //
        // Without this the query matched on class + synchronizable alone, so a
        // single FOREIGN non-synchronizable `kSecClassKey` item written by anything
        // else sharing the access group pinned `hasLocalKey` to true forever ->
        // `observedKeySyncState()` to false -> `isSyncEnabled` to false on the
        // `.notSet` path -> every write local-only. That is the conservative
        // outcome the comment above argues for, but arrived at by accident, from an
        // item with nothing to do with Encamera, and indistinguishable in the logs.
        // It also defeated `backupKeychainToiCloud`'s partial-flip detection, which
        // reports `actual = observedKeySyncState() ?? !backupEnabled`.
        //
        // Still deliberately judged on RAW items rather than `storedKeys()`
        // (ENC-98): a key item that fails to decode is still a key in some sync
        // scope, and decoding first would hide it.
        func encameraKeyItemExists(synchronizable: CFBoolean) -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrSynchronizable as String: synchronizable,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var item: CFTypeRef?
            guard keychainWrapper.secItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let items = item as? [[String: Any]] else {
                return false
            }
            let prefix = KeychainConstants.applicationTag
            return items.contains { attributes in
                guard let tagData = attributes[kSecAttrApplicationTag as String] as? Data,
                      let tag = String(data: tagData, encoding: .utf8) else {
                    return false
                }
                return tag.hasPrefix(prefix)
            }
        }

        let hasLocalKey = encameraKeyItemExists(synchronizable: kCFBooleanFalse!)
        let hasSyncedKey = encameraKeyItemExists(synchronizable: kCFBooleanTrue!)
        guard hasLocalKey || hasSyncedKey else {
            return nil
        }
        return !hasLocalKey
    }

    /// True when a local and a synced copy of this generic-password account both
    /// exist and hold different bytes — a genuine credential conflict rather
    /// than the ordinary redundant duplicate a second device accumulates.
    private func hasDivergentCredentialPair(account: String) -> Bool {
        guard let local = genericPasswordData(account: account, synchronizable: false),
              let synced = genericPasswordData(account: account, synchronizable: true) else {
            return false
        }
        return local != synced
    }

    /// Moves every secret the app owns on or off the iCloud keychain, then
    /// records the new state in the central backup flag.
    ///
    /// Items first, flag last, and deliberately so: the flag is what
    /// `isSyncEnabled` — and therefore the Settings toggle — reads, so writing
    /// it before the items can leave the app reporting "backup off" over
    /// secrets that are still syncing.
    ///
    /// Each item is flipped independently and failures are collected, so a
    /// single failing item can't silently leave everything after it unflipped
    /// (which strands that item local-only and unable to sync). On any failure
    /// the flag is re-derived from what the items are *actually* in and the
    /// caller is told both what was attempted and where it ended up.
    public func backupKeychainToiCloud(backupEnabled: Bool) throws {
        printDebug("backupKeychainToiCloud(\(backupEnabled)) — state before flip:")
        logCredentialVariantState(context: "before flip")

        var failures: [String] = []

        // Every key item, enumerated raw rather than through `storedKeys()`:
        // a key blob this version cannot decode still syncs, and leaving it
        // behind would leave key material on iCloud after the user asked for
        // it to come off (ENC-98).
        do {
            for identity in try encameraKeyIdentities() {
                let label = (identity[kSecAttrLabel as String] as? Data)
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "<unlabelled>"
                do {
                    try setSynchronizable(backupEnabled,
                                          forItemMatching: identity,
                                          description: "key \(label)")
                } catch {
                    printDebug("flip: key '\(label)' FAILED:", error)
                    // Named by fingerprint, not display name: every key in normal
                    // use is called `encamera_default_key`, so a name cannot say
                    // *which* of an N-key library failed to flip (ENC-98).
                    failures.append("key \(label): \(error)")
                }
            }
        } catch {
            printDebug("flip: could not enumerate key items:", error)
            failures.append("keyItems: \(error)")
        }

        // The generic-password credentials. `setSynchronizable` collapses a
        // coexisting local + synced pair to one copy, which picks a winner — so
        // when the two DIFFER (ENC-105: the aftermath of onboarding on two
        // devices with different key phrases) the direction of the flip decides
        // whether that is allowed:
        //
        // - Turning backup OFF collapses regardless. Taking the secret off
        //   iCloud is the whole point of the request; leaving a differing synced
        //   copy on the account because the two disagreed would keep the user's
        //   secrets exactly where they asked for them not to be.
        // - Turning backup ON leaves the pair alone. Nothing about enabling
        //   backup requires resolving it, and silently picking a side would
        //   decide a question that belongs to the user. Both items stay intact
        //   so `detectCredentialConflicts()` keeps surfacing it and the chosen
        //   `conflictResolution` keeps pinning every read and write.
        let genericCredentials: [(account: String, description: String)] = [
            (KeychainConstants.passPhraseKeyItem, "key passphrase"),
            (KeychainConstants.passcodeTypeKeyItem, "passcode type"),
            (KeychainConstants.account, "password hash"),
        ]

        for credential in genericCredentials {
            if backupEnabled && hasDivergentCredentialPair(account: credential.account) {
                printDebug("flip: \(credential.description) left unflipped — local and synced copies differ, leaving the choice to conflictResolution")
                continue
            }
            do {
                try setSynchronizable(backupEnabled, forItemMatching: [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: credential.account
                ], description: credential.description)
            } catch {
                printDebug("flip: \(credential.description) FAILED:", error)
                failures.append("\(credential.description): \(error)")
            }
        }

        printDebug("backupKeychainToiCloud(\(backupEnabled)) — state after flip:")
        logCredentialVariantState(context: "after flip")

        guard failures.isEmpty else {
            printDebug("backupKeychainToiCloud FAILURES: \(failures.joined(separator: "; "))")

            // Deliberately NOT rolling the item flips back (ENC-86 step 5).
            // A rollback is itself a series of account-wide synced writes over
            // the same items that just failed; a rollback that also fails leaves
            // the account in a *worse*, half-flipped state than simply telling
            // the truth about where it ended up. What must hold is that the flag
            // never lies: `isSyncEnabled` is what the Settings toggle renders, so
            // re-derive the flag from the items themselves and report the real
            // state to the caller.
            let actual = observedKeySyncState() ?? !backupEnabled
            do {
                try writeBackupFlag(enabled: actual)
            } catch {
                // Nothing further to do: the error below still carries the
                // observed state, so the UI can show reality even when the
                // flag itself turns out to be unwritable.
                printDebug("flip: could not correct backup flag:", error)
            }

            throw KeyManagerError.syncFlipFailed(
                attempted: backupEnabled,
                actual: actual,
                details: failures.joined(separator: "; ")
            )
        }

        try writeBackupFlag(enabled: backupEnabled)
    }

    /// A base query per distinct Encamera key item the app can see, synced
    /// copies included and deduplicated — one identity normally has both a
    /// local and an iCloud-delivered copy.
    ///
    /// Scoped by `kSecAttrApplicationTag` for the same reason
    /// `observedKeySyncState()` is: a foreign `kSecClassKey` item written by
    /// anything else sharing the access group is not ours to move.
    private func encameraKeyIdentities() throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        try checkStatus(status: status)
        guard let items = item as? [[String: Any]] else {
            return []
        }

        let prefix = KeychainConstants.applicationTag
        var identities: [[String: Any]] = []
        var seen: [Data] = []
        for attributes in items {
            guard let tagData = attributes[kSecAttrApplicationTag as String] as? Data,
                  let tag = String(data: tagData, encoding: .utf8),
                  tag.hasPrefix(prefix) else { continue }
            guard let label = attributes[kSecAttrLabel as String] as? Data else { continue }
            if seen.contains(label) { continue }
            seen.append(label)

            // The full identity, not just the label: for `kSecClassKey` the
            // primary key is applicationLabel/applicationTag/keyType/…, so a
            // query on `kSecAttrLabel` alone can match a key that is not this
            // one, and an add built from it would write an item the app can no
            // longer recognize as its own.
            var identity: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: label,
                kSecAttrApplicationTag as String: tagData
            ]
            if let applicationLabel = attributes[kSecAttrApplicationLabel as String] {
                identity[kSecAttrApplicationLabel as String] = applicationLabel
            }
            identities.append(identity)
        }
        return identities
    }

    /// Leaves exactly one copy of the matched item behind, carrying the data
    /// that was in use, marked `synchronizable == enabled`.
    ///
    /// It cannot be done with a single `SecItemUpdate`. Once a device holds
    /// both a local and an iCloud-delivered copy of an item — the normal state
    /// of any second device — an update that would collapse the two onto one
    /// sync value collides, and the keychain refuses it with
    /// `errSecDuplicateItem` without changing anything. That refusal, swallowed
    /// by the toggle, is why key backup could not be turned off.
    /// `KeychainSyncFlipPlatformContractTests` pins the behavior against the
    /// real Security framework.
    ///
    /// So: write the target copy FIRST, then delete the other. Never the
    /// reverse — a delete-then-add that is interrupted (backgrounded, killed,
    /// device locked) between the two steps would destroy the only copy of the
    /// user's key and with it every encrypted file.
    ///
    /// Deleting the synchronizable copy is what takes the secret off iCloud:
    /// the deletion propagates, so the other devices drop their copies too.
    /// That is precisely what turning key backup off means.
    private func setSynchronizable(_ enabled: Bool,
                                   forItemMatching baseQuery: [String: Any],
                                   description: String) throws {
        var readQuery = baseQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecReturnAttributes as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        readQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let readStatus = keychainWrapper.secItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecItemNotFound {
            return
        }
        try checkStatus(status: readStatus)
        guard let copies = result as? [[String: Any]], !copies.isEmpty else {
            return
        }

        let target = enabled ? kCFBooleanTrue! : kCFBooleanFalse!
        let other = enabled ? kCFBooleanFalse! : kCFBooleanTrue!
        let copiesInTargetState = copies.filter { syncFlag(of: $0) == enabled }

        // Nothing to do when the item is already the single copy it should be.
        if copies.count == 1 && copiesInTargetState.count == 1 {
            return
        }

        // The copy whose bytes survive: the one the app has been reading, i.e.
        // the one whose sync flag matches the state we are leaving. Falls back
        // to any copy, so a keychain in an unexpected shape still converges.
        let winner = copies.first { syncFlag(of: $0) != enabled } ?? copies[0]
        guard let winningData = winner[kSecValueData as String] as? Data else {
            throw KeyManagerError.dataError
        }

        // 1. Make sure a copy with the target flag exists, holding those bytes.
        if copiesInTargetState.isEmpty {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = winningData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            addQuery[kSecAttrSynchronizable as String] = target
            if let creationDate = winner[kSecAttrCreationDate as String] {
                addQuery[kSecAttrCreationDate as String] = creationDate
            }
            if let applicationLabel = winner[kSecAttrApplicationLabel as String] {
                addQuery[kSecAttrApplicationLabel as String] = applicationLabel
            }
            if let applicationTag = winner[kSecAttrApplicationTag as String] {
                addQuery[kSecAttrApplicationTag as String] = applicationTag
            }
            try checkStatus(status: keychainWrapper.secItemAdd(addQuery as CFDictionary, nil))
        } else {
            var updateQuery = baseQuery
            updateQuery[kSecAttrSynchronizable as String] = target
            let attributes: [String: Any] = [
                kSecValueData as String: winningData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ]
            try checkStatus(status: keychainWrapper.secItemUpdate(updateQuery as CFDictionary,
                                                                  attributes as CFDictionary))
        }

        // 2. Drop the copies on the other side. Only now is it safe.
        var deleteQuery = baseQuery
        deleteQuery[kSecAttrSynchronizable as String] = other
        let deleteStatus = keychainWrapper.secItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecItemNotFound {
            try checkStatus(status: deleteStatus)
        }

        printDebug("Set \(description) synchronizable=\(enabled)")
    }

    private func syncFlag(of attributes: [String: Any]) -> Bool {
        let value = attributes[kSecAttrSynchronizable as String]
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    /// See `KeyManager.enableMultiDeviceMode`.
    ///
    /// The retention guarantee this ticket exists for: whatever iCloud Keychain
    /// does when this device's credentials meet the account's, every key the
    /// device held before the flip is still in the library afterwards, and the
    /// key it writes new media with does not change underneath the user. The
    /// losing key of a conflict stays as a decrypt-only library entry (ENC-78 /
    /// ENC-79), never overwritten.
    public func enableMultiDeviceMode() throws {
        let keysBefore = (try? storedKeys()) ?? []
        let activeFingerprintBefore = (try? getActiveKey())?.keychainLabel

        var flipError: Error?
        do {
            try backupKeychainToiCloud(backupEnabled: true)
        } catch {
            // Retention still has to run: a partial flip is exactly the case
            // where a key can have gone missing.
            flipError = error
        }

        // The retention guarantee is only a guarantee if its failures reach the
        // caller. A key that fails to restore here is GONE — it was already observed
        // missing from `storedKeys()` after the flip, this is the last chance to put
        // it back, and unless it happens to be the default key derivable from a
        // synced passphrase, `restoreDefaultKeyFromPassphraseIfNeeded()` cannot
        // bring it back either. Swallowed with `try?` it used to be reported as a
        // successful "Multi-Device Mode is on" while a key silently vanished.
        var retentionFailures: [String] = []
        let survivingFingerprints = Set(((try? storedKeys()) ?? []).map(\.keychainLabel))
        for key in keysBefore where !survivingFingerprints.contains(key.keychainLabel) {
            printDebug("enableMultiDeviceMode: restoring key \(key.keychainLabel) lost during the flip")
            do {
                // `setNewKeyToCurrent: false` — a restored key is a library key.
                // Promoting it here would be its own silent repoint.
                try save(key: key, setNewKeyToCurrent: false)
            } catch {
                printDebug("enableMultiDeviceMode: FAILED to restore key \(key.keychainLabel):", error)
                retentionFailures.append("key \(key.keychainLabel) lost: \(error)")
            }
        }

        // Re-pin the pre-flip active key. Keys arriving from iCloud must not
        // change which key this device encrypts with; that is a user decision — so
        // a failure here is reported too, rather than leaving the user told the
        // mode is on while the key they encrypt with changed underneath them.
        if let activeFingerprintBefore, let key = keyWith(fingerprint: activeFingerprintBefore) {
            do {
                try setActiveKey(key)
            } catch {
                printDebug("enableMultiDeviceMode: FAILED to re-pin the active key:", error)
                retentionFailures.append("active key \(activeFingerprintBefore) not re-pinned: \(error)")
            }
        }

        guard retentionFailures.isEmpty else {
            // Retention failures subsume the flip error: they are the strictly worse
            // outcome, and the flip's own details are folded in so nothing is lost.
            var details = retentionFailures.joined(separator: "; ")
            if let flipError {
                details += "; flip: \(flipError)"
            }
            throw KeyManagerError.syncFlipFailed(
                attempted: true,
                actual: observedKeySyncState() ?? false,
                details: details
            )
        }

        if let flipError {
            throw flipError
        }
    }

    /// See `KeyManager.multiDeviceKeyConflict`.
    public func multiDeviceKeyConflict() -> MultiDeviceKeyConflict? {
        let localFingerprints = Set(((try? storedKeys()) ?? []).map(\.keychainLabel))
        let accountFingerprints = getMultiDeviceState()?.keyFingerprints ?? []
        let remoteOnly = accountFingerprints.filter { !localFingerprints.contains($0) }
        guard !remoteOnly.isEmpty else {
            return nil
        }
        return MultiDeviceKeyConflict(
            localFingerprint: (try? getActiveKey())?.keychainLabel,
            remoteFingerprints: remoteOnly
        )
    }

    /// Moves a single key on or off the iCloud keychain. Routed through
    /// `setSynchronizable` like everything else — the one-shot `SecItemUpdate`
    /// this used to do cannot flip a key that has both a local and an
    /// iCloud-delivered copy, which is the normal state of any second device.
    /// `setSynchronizable` writes the target copy before deleting the other, so
    /// no interruption can leave the key material gone.
    public func update(key: PrivateKey, backupToiCloud: Bool) throws {
        guard var query = existingKeyItemQuery(for: key) else {
            throw KeyManagerError.notFound
        }
        // The identity attributes only — `setSynchronizable` supplies the sync
        // scope, the value data, and the accessibility itself.
        query.removeValue(forKey: kSecAttrSynchronizable as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query.removeValue(forKey: kSecReturnData as String)

        try setSynchronizable(backupToiCloud,
                              forItemMatching: query,
                              description: "key \(key.keychainLabel) ('\(key.name)')")
        printDebug("Key updated: \(key.name), iCloud: \(backupToiCloud)")
    }

    public func keyWith(name: String) -> PrivateKey? {

        let keys = try? storedKeys()
        return keys?.first(where: {$0.name == name})
    }

    /// Identity lookup. Names are display metadata and may repeat across keys;
    /// the fingerprint is what uniquely identifies a key.
    public func keyWith(fingerprint: String) -> PrivateKey? {
        let keys = try? storedKeys()
        return keys?.first(where: { $0.keychainLabel == fingerprint })
    }

    /// Removes one key from the library.
    ///
    /// Refuses to remove the last remaining key or the key that is currently
    /// active — both throw rather than silently no-op, because a caller that
    /// hits either has a logic error and would otherwise leave the app with no
    /// usable key.
    public func deleteKey(fingerprint: String, scope: KeyDeletionScope = .deviceLocal) throws {
        let keys = try storedKeys()
        guard keys.contains(where: { $0.keychainLabel == fingerprint }) else {
            throw KeyManagerError.notFound
        }
        guard keys.count > 1 else {
            throw KeyManagerError.keyDeletionFailed
        }
        // Compared against the PERSISTED pointer, not the in-memory `currentKey`
        // mirror. `currentKey` is only populated by `setActiveKey`, which runs from
        // the `isAuthenticated` sink — before the first successful authentication it
        // is nil, so an in-memory check passes and the key the persisted pointer
        // names can be deleted. `getActiveKey()` then falls through to `notFound`,
        // `attemptKeyRestoreAfterFailedLoad()` clears the pointer, and whatever
        // `storedKeys().first` happens to be gets promoted — a real path to losing
        // the active pinning from the key-management UI.
        //
        // Resolved the same way `getActiveKey()` resolves it — post-migration the
        // pointer is a fingerprint, pre-migration installs stored a display name —
        // but WITHOUT `getActiveKey()`'s side effect of auto-pinning the first
        // stored key when no pointer exists.
        let activeFingerprint: String?
        if let pointer = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String {
            activeFingerprint = PrivateKey.isFingerprintLabel(pointer)
                ? pointer
                : keys.first(where: { $0.name == pointer })?.keychainLabel
        } else {
            activeFingerprint = currentKey?.keychainLabel
        }
        if activeFingerprint == fingerprint {
            throw KeyManagerError.keyDeletionFailed
        }

        guard let labelData = fingerprint.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: labelData,
            kSecAttrApplicationLabel as String: labelData,
        ]
        switch scope {
        case .deviceLocal:
            // Targets only the non-synchronizable copy, so the deletion is not
            // tombstoned to the rest of the account.
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        case .accountWide:
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }

        let status = keychainWrapper.secItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            printDebug("deleteKey: FAILED fingerprint=\(fingerprint) scope=\(scope) status=\(status) (\(determineOSStatus(status: status)))")
            throw KeyManagerError.keyDeletionFailed
        }
        printDebug("deleteKey: removed fingerprint=\(fingerprint) scope=\(scope)")
    }

    @MainActor
    public func keyWith(uuid: UUID) -> PrivateKey? {
        // If we're in background and it's the current key, return it directly
        if UIApplication.shared.applicationState == .background,
           let currentKey = currentKey,
           currentKey.uuid == uuid {
            printDebug("Returning cached key in background for UUID: \(uuid)")
            return currentKey
        }

        // Otherwise, try normal keychain access
        let keys = try? storedKeys()
        return keys?.first(where: {$0.uuid == uuid})
    }

    public func storedKeys() throws -> [PrivateKey] {

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Match any existing item
        ]

        return try keysFromQuery(query: query)
    }

    private func keysFromQuery(query: [String: Any]) throws -> [PrivateKey]  {
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)

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
        try setActiveKey(key)
    }

    /// Pins the current key by fingerprint. Display names are no longer unique,
    /// so a name is not enough to identify which key is current.
    public func setActiveKey(_ key: PrivateKey) throws {
        currentKey = key
        UserDefaultUtils.set(key.keychainLabel, forKey: UserDefaultKey.currentKey)
    }

    func getActiveKey() throws -> PrivateKey {
        guard let activeKeyRef = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String else {
            guard let firstStoredKey = try storedKeys().first else {
                throw KeyManagerError.notFound
            }
            // Only auto-set the first key as current if we're not in a test scenario
            // where we explicitly don't want any current key set
            try setActiveKey(firstStoredKey)
            return firstStoredKey
        }
        // Post-migration the pointer is a fingerprint. Installs predating the
        // migration stored a display name, so fall back to a name lookup and
        // re-pin by fingerprint so the fallback is taken at most once.
        if PrivateKey.isFingerprintLabel(activeKeyRef), let key = keyWith(fingerprint: activeKeyRef) {
            return key
        }
        let key = try getKey(by: activeKeyRef)
        try setActiveKey(key)
        return key
    }

    func getKey(by keyName: KeyName) throws -> PrivateKey {



        // Scans the library rather than querying by label: the label now carries
        // the fingerprint, not the name. Ambiguous by nature once two keys share
        // a display name — returns the first in `storedKeys()` order.
        guard let key = keyWith(name: keyName) else {
            throw KeyManagerError.notFound
        }
        return key
    }

    public func keyPassphraseExists() ->  Bool  {
        let passphraseStatus = keychainWrapper.secItemCopyMatching(queryForPassphrase() as CFDictionary, nil)
        do {
            try checkStatus(status: passphraseStatus)
        } catch {
            printDebug("keyPassphraseExists: unexpected passphrase query status \(passphraseStatus) (\(determineOSStatus(status: passphraseStatus)))")

            return false
        }
        return true
    }

    public func passwordExists() -> Bool {

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true, // Added to retrieve attributes
            // Use helper computed property for query value
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        
        // Print details if successful
        if status == errSecSuccess, let existingItem = item as? [String: Any] {

            
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
        let passwordStatus = keychainWrapper.secItemDelete(passwordQuery as CFDictionary)
        // Ignore item not found, throw on other errors
        if passwordStatus != errSecItemNotFound {
            try checkStatus(status: passwordStatus)
        }

        // Query for the legacy passcode type item
        let passcodeTypeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Ensure we find it regardless of sync status
        ]
        let passcodeTypeStatus = keychainWrapper.secItemDelete(passcodeTypeQuery as CFDictionary)
        // Ignore item not found, throw on other errors
        if passcodeTypeStatus != errSecItemNotFound {
            try checkStatus(status: passcodeTypeStatus)
        }

        // Keep the AuthenticationConfiguration in sync — with the password
        // gone, no passcode type is enabled anymore.
        if var config = getAuthenticationConfiguration(), let type = config.passcodeType {
            config.removeAuthenticationType(.passcode(type))
            try setAuthenticationConfiguration(config: config)
        }
    }
    
    public func setPassword(_ password: String, type: PasscodeType) throws {
        let hashed = try hashFrom(password: password)
        try setPasswordHash(hash: hashed)
        try savePasscodeTypeToKeychain(type)
    }

    public func setOrUpdatePassword(_ password: String, type: PasscodeType) throws {
        let hashed = try hashFrom(password: password)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecAttrSynchronizable as String: syncValueForWrites // Use helper
        ]

        let update: [String: Any] = [
            kSecValueData as String: hashed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: syncValueForWrites // Use helper
        ]

        let status = keychainWrapper.secItemUpdate(query as CFDictionary, update as CFDictionary)

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
        let deletePasswordStatus = keychainWrapper.secItemDelete(query as CFDictionary)
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
            // Use helper computed property for query value
            kSecAttrSynchronizable as String: syncQueryValueForReads
        ]
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: syncValueForWrites // Use helper
        ]
        let setPasswordStatus = keychainWrapper.secItemAdd(query as CFDictionary, nil)

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
                kSecAttrSynchronizable as String: syncValueForWrites // Use helper
            ]
            let updateStatus = keychainWrapper.secItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
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
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
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
            let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &items)

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

    /// Relabels name-addressed key items to fingerprint-addressed ones, in
    /// place. Idempotent — items already carrying a fingerprint label are left
    /// untouched, so it is safe to run on every launch.
    ///
    /// Uses `SecItemUpdate` exclusively and never `SecItemDelete`: deleting a
    /// synchronizable item tombstones it account-wide and the deletion
    /// propagates to every other device (ENC-72). Each item is targeted in its
    /// own sync scope so a local and a synced copy of the same key are
    /// relabelled independently rather than one clobbering the other.
    @discardableResult
    public func migrateKeyLabelsToFingerprintsIfNeeded() throws -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return 0 }
        try checkStatus(status: status)
        guard let items = item as? [[String: Any]] else { return 0 }

        var relabelled = 0
        for keychainItem in items {
            guard let labelData = keychainItem[kSecAttrLabel as String] as? Data,
                  let existingLabel = String(data: labelData, encoding: .utf8) else {
                continue
            }
            guard !PrivateKey.isFingerprintLabel(existingLabel) else {
                continue // already migrated
            }
            guard let key = try? PrivateKey(keychainItem: keychainItem) else {
                printDebug("migrateKeyLabels: skipping undecodable item labelled \(existingLabel)")
                continue
            }

            let isSynced = (keychainItem[kSecAttrSynchronizable as String] as? Bool) ?? false
            let targetQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: labelData,
                kSecAttrSynchronizable as String: isSynced ? kCFBooleanTrue! : kCFBooleanFalse!
            ]
            let updateStatus = keychainWrapper.secItemUpdate(
                targetQuery as CFDictionary,
                key.keychainIdentityAttributes as CFDictionary
            )
            if updateStatus == errSecSuccess {
                relabelled += 1
                printDebug("migrateKeyLabels: relabelled \(existingLabel) -> \(key.keychainLabel) (synced=\(isSynced))")
            } else {
                printDebug("migrateKeyLabels: FAILED to relabel \(existingLabel) — status \(updateStatus) (\(determineOSStatus(status: updateStatus)))")
            }
        }

        // Re-pin an existing name-based pointer onto the fingerprint. Guarded on
        // a pointer already being set: getActiveKey() promotes the first stored
        // key when there is none, and migration must never choose a current key.
        if relabelled > 0,
           let pointer = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String,
           !PrivateKey.isFingerprintLabel(pointer) {
            _ = try? getActiveKey()
        }
        printDebug("migrateKeyLabels: relabelled \(relabelled) of \(items.count) key items")
        return relabelled
    }

    // Added private func for legacy migration
    public func migrateLegacyKeysIfNeeded() throws {
        try migrateKeyLabelsToFingerprintsIfNeeded()
        
        let keys = try storedKeys()
        
        guard !keys.isEmpty else {
            printDebug("No keys found, skipping migration")
            return
        }
        
        printDebug("Starting migration for \(keys.count) keys")

        for key in keys {
            do {
                // For migration, preserve the original sync status of each key
                let originalSyncStatus = try isKeyItemSynced(fingerprint: key.keychainLabel)
                
                // Re-save the key to ensure it's in the current format while preserving sync status
                try saveKeyPreservingSync(key: key, syncStatus: originalSyncStatus)
                printDebug("Successfully processed key: \(key.name)")
            } catch {
                printDebug("Failed to migrate key \(key.name): \(error)")
                throw error
            }
        }
        
        printDebug("Migration completed for \(keys.count) keys")
    }
    
    private func saveKeyPreservingSync(key: PrivateKey, syncStatus: Bool) throws {
        var query = key.keychainQueryDictForKeychain
        query[kSecAttrSynchronizable as String] = syncStatus ? kCFBooleanTrue! : kCFBooleanFalse!

        // Find the item by fingerprint, falling back to a legacy name label.
        if let baseQuery = existingKeyItemQuery(for: key) {
            // Key exists, update it. Creation date is deliberately left alone —
            // storedKeys() sorts by it.
            var updateQuery: [String: Any] = [
                kSecValueData as String: key.keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncStatus ? kCFBooleanTrue! : kCFBooleanFalse!,
            ]
            updateQuery.merge(key.keychainIdentityAttributes) { current, _ in current }
            let updateStatus = keychainWrapper.secItemUpdate(baseQuery as CFDictionary, updateQuery as CFDictionary)
            try self.checkStatus(status: updateStatus)
        } else {
            // Key doesn't exist, add it
            let addStatus = keychainWrapper.secItemAdd(query as CFDictionary, nil)
            try self.checkStatus(status: addStatus)
        }
    }
    
    private func isKeyItemSynced(fingerprint: String) throws -> Bool {
        var query = try keyIdentityQuery(forFingerprint: fingerprint)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return false
            } else {
                throw KeyManagerError.unhandledError("Error checking sync status: \(status)")
            }
        }
        
        guard let attributes = item as? [String: Any] else {
            return false
        }
        
        let syncAttribute = attributes[kSecAttrSynchronizable as String]
        
        if let isSyncedBool = syncAttribute as? Bool {
            return isSyncedBool
        } else if let isSyncedNum = syncAttribute as? NSNumber {
            return isSyncedNum.boolValue
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
            // Use helper computed property for query value
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
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
    
    /// Re-pins the resolved active key by its own identity. Deliberately NOT
    /// `setActiveKey(keyObject.name)`: a name round-trip goes back through
    /// `getKey(by:)` -> `keyWith(name:)` -> `storedKeys().first(where:)`, and
    /// `storedKeys()` sorts ascending by creation date, so the name lookup
    /// resolves to the OLDEST key carrying that name. Once a library holds
    /// several keys all named `encamera_default_key` (ENC-78), that runs on
    /// every unlock and silently demotes whatever was pinned — undoing
    /// `enableMultiDeviceMode()`'s re-pin and a returning user's freshly
    /// imported key. `testActiveKeyPointerSurvivesRepeatedAuthentication` pins this.
    private func getActiveKeyAndSet() throws {
        let keyObject = try getActiveKey()
        try setActiveKey(keyObject)
    }
    
    // `getKeyQuery(for:)` was removed with ENC-79. It scoped its lookup by
    // `syncQueryValueForReads`, so with the backup flag disabled a synced key
    // item was invisible and `save` took the add branch against an item that
    // already existed. Key lookups now go through `storedKeys()` (which queries
    // `kSecAttrSynchronizableAny`) and existence probes through
    // `keyIdentityQuery(forFingerprint:)`, which does the same.

    /// Targets a single key item by fingerprint identity, regardless of its
    /// sync state, for update and existence probes.
    private func keyIdentityQuery(forFingerprint fingerprint: String) throws -> [String: Any] {
        guard let labelData = fingerprint.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        return [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: labelData,
            kSecAttrApplicationLabel as String: labelData,
            // Existence probes must use Any, never syncQueryValueForReads: with
            // the backup flag disabled, a synced item would be invisible and
            // save() would SecItemAdd over an item that already exists.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    /// True when a key with these bytes is already stored, in either sync scope.
    func keyItemExists(fingerprint: String) -> Bool {
        guard var query = try? keyIdentityQuery(forFingerprint: fingerprint) else {
            return false
        }
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return keychainWrapper.secItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Targets a pre-migration item, which is still labelled with its display
    /// name rather than a fingerprint.
    private func legacyKeyItemQuery(forName name: KeyName) -> [String: Any]? {
        guard let nameData = name.data(using: .utf8) else { return nil }
        return [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: nameData,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    /// Locates the stored item for `key`, preferring fingerprint identity and
    /// falling back to the legacy name label so that installs which have not yet
    /// run `migrateKeyLabelsToFingerprintsIfNeeded()` still update in place
    /// instead of gaining a duplicate.
    private func existingKeyItemQuery(for key: PrivateKey) -> [String: Any]? {
        if keyItemExists(fingerprint: key.keychainLabel) {
            return try? keyIdentityQuery(forFingerprint: key.keychainLabel)
        }
        guard var legacy = legacyKeyItemQuery(forName: key.name) else { return nil }
        var probe = legacy
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        probe[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard keychainWrapper.secItemCopyMatching(probe as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        // A name match alone is not identity. Every production key is called
        // `encamera_default_key`, so importing a second key phrase on an
        // install that has not yet been relabelled would otherwise update the
        // existing item in place and destroy the material every already-encrypted
        // file depends on (ENC-97). Only reuse the legacy item when its bytes
        // really are this key's.
        guard let data = item as? Data,
              Self.storedKeyBytes(from: data) == key.keyBytes else {
            return nil
        }
        legacy.removeValue(forKey: kSecMatchLimit as String)
        return legacy
    }

    /// Key material out of a stored `kSecValueData`, in either shipped
    /// encoding: the current JSON `KeyCore` blob, or the pre-migration raw
    /// bytes that `migrateLegacyKeysIfNeeded()` still upgrades. Mirrors the
    /// same fallback in `PrivateKey.init(keychainItem:)`.
    private static func storedKeyBytes(from data: Data) -> KeyBytes {
        if let decoded = try? PrivateKey(name: AppConstants.defaultKeyName, keyData: data, creationDate: Date()) {
            return decoded.keyBytes
        }
        return Array(data)
    }

    private func updateKeyQuery(forFingerprint fingerprint: String) throws -> CFDictionary {
        return try keyIdentityQuery(forFingerprint: fingerprint) as CFDictionary
    }
    
    /// Persists the passcode type into the AuthenticationConfiguration. The
    /// deprecated standalone item (`encamera_passcode_type`) is no longer
    /// written — it remains only as a read fallback in
    /// `retrieveLegacyPasscodeTypeFromKeychain`.
    private func savePasscodeTypeToKeychain(_ passcodeType: PasscodeType) throws {
        var config = getAuthenticationConfiguration() ?? AuthenticationConfiguration(enabledTypes: [])
        config.addAuthenticationType(.passcode(passcodeType))
        try setAuthenticationConfiguration(config: config)
    }
    
    private func retrievePasscodeTypeFromKeychain() throws -> PasscodeType {
        // The AuthenticationConfiguration is the source of truth for the
        // passcode type. Fall back to the deprecated standalone item for
        // installs whose configuration hasn't been written yet.
        if let type = getAuthenticationConfiguration()?.passcodeType {
            return type
        }
        return try retrieveLegacyPasscodeTypeFromKeychain()
    }

    /// Reads the deprecated standalone passcode-type item
    /// (`encamera_passcode_type`). New writes go into the
    /// AuthenticationConfiguration; this exists only as a read fallback until
    /// the type has been written there.
    private func retrieveLegacyPasscodeTypeFromKeychain() throws -> PasscodeType {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecReturnData as String: true,
            // Use helper computed property for query value
            kSecAttrSynchronizable as String: syncQueryValueForReads
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        try checkStatus(status: status)

        guard let data = item as? Data else {
            throw KeyManagerError.dataError
        }

        let decoder = JSONDecoder()
        return try decoder.decode(PasscodeType.self, from: data)
    }

    // --- Private Helpers for Sync Status Handling ---

    /// Determines the explicit state of the central backup status flag.
    private func getBackupFlagState() -> BackupFlagState {
        guard let status = getBackupStatus() else { return .notSet }
        return status.enabled ? .enabled : .disabled
    }

    /// Reads and decodes the central backup status item. Both payload formats
    /// must stay readable forever: a device on an older app version can rewrite
    /// the legacy boolean at any time, and the item syncs.
    private func getBackupStatus() -> KeychainBackupStatus? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Find it regardless of its internal sync status
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                print("Warning: Found backup status flag but couldn't read its data.")
                return nil
            }
            return Self.decodeBackupStatus(from: data)
        case errSecItemNotFound:
            return nil
        default:
            print("Error reading backup status flag: \(determineOSStatus(status: status)). Assuming not set.")
            return nil
        }
    }

    static func decodeBackupStatus(from data: Data) -> KeychainBackupStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let status = try? decoder.decode(KeychainBackupStatus.self, from: data) {
            return status
        }
        // Legacy format: the flag was a raw Int-width boolean with no metadata.
        if let boolVal = data.boolValue {
            return KeychainBackupStatus(enabled: boolVal, deviceID: nil, deviceName: nil, timestamp: nil)
        }
        print("Warning: Found backup status flag but couldn't decode its value.")
        return nil
    }

    static func encodeBackupStatus(_ status: KeychainBackupStatus) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(status)
    }

    /// One-time migration of the backup status item's payload from the legacy
    /// raw boolean to the structured `KeychainBackupStatus` JSON. Preserves
    /// `enabled`; the flipping device was never recorded in the legacy format,
    /// so the metadata stays nil rather than claiming this device flipped it.
    /// Only writes when the legacy format is actually present.
    public func migrateLegacyBackupStatusIfNeeded() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        guard keychainWrapper.secItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return
        }
        // Already JSON — nothing to migrate.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if (try? decoder.decode(KeychainBackupStatus.self, from: data)) != nil {
            return
        }
        guard let legacyEnabled = data.boolValue else {
            printDebug("migrateLegacyBackupStatus: item present but not legacy bool or JSON — leaving as-is")
            return
        }

        let migrated = KeychainBackupStatus(enabled: legacyEnabled, deviceID: nil, deviceName: nil, timestamp: nil)
        guard let payload = try? Self.encodeBackupStatus(migrated) else { return }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let newAttributes: [String: Any] = [
            kSecValueData as String: payload
        ]
        let status = keychainWrapper.secItemUpdate(updateQuery as CFDictionary, newAttributes as CFDictionary)
        printDebug("migrateLegacyBackupStatus: rewrote legacy bool (enabled=\(legacyEnabled)) as JSON — status \(status) (\(determineOSStatus(status: status)))")
    }

    /// The value for `kSecAttrSynchronizable` in READ queries.
    ///
    /// A chosen conflict resolution still pins reads to one credential set, so
    /// that two genuinely different coexisting credentials don't make lookups
    /// nondeterministic — that pin is a decision the user made.
    ///
    /// Absent one it is always "either". It used to fall back to narrowing by
    /// the backup flag — synced items when backup was on, local ones when off —
    /// which meant any disagreement between the flag and an item made that item
    /// invisible to the app. Not a theoretical state: build 1087 wrote the flag
    /// and then failed to move the items, and the on-device rig reproduced the
    /// consequence directly — the flag read ON, `encamera_default_key` existed
    /// only as a local copy, and the app could not load its own key ("Error
    /// during initial key setup: notFound") even though `storedKeys()`, which
    /// always queried both, could see it perfectly well.
    ///
    /// Reading both makes the app find its key whatever state a previous
    /// version left behind. Ambiguity is bounded: `setSynchronizable` collapses
    /// an item to a single copy whenever backup is toggled.
    private var syncQueryValueForReads: CFTypeRef {
        switch conflictResolution {
        case .preferLocal: return kCFBooleanFalse!
        case .preferSynced: return kCFBooleanTrue!
        case nil: return kSecAttrSynchronizableAny
        }
    }

    /// Provides the correct value for kSecAttrSynchronizable in write/update operations.
    /// Pinned like reads while a conflict resolution is active, so updates land
    /// on the credential set the user chose.
    private var syncValueForWrites: CFBoolean {
        switch conflictResolution {
        case .preferLocal: return kCFBooleanFalse!
        case .preferSynced: return kCFBooleanTrue!
        case nil: break
        }
        return self.isSyncEnabled ? kCFBooleanTrue! : kCFBooleanFalse!
    }

    // --------------------------------------------------

}

extension PrivateKey {

    /// The display name, stored outside the item's identity attributes.
    var applicationTagValue: String {
        "\(KeychainConstants.applicationTag).\(name)"
    }

    /// Identity is the fingerprint, written to BOTH `kSecAttrLabel` and
    /// `kSecAttrApplicationLabel`.
    ///
    /// `kSecAttrApplicationLabel` is what actually matters to the Security
    /// framework: for `kSecClassKey` the primary key is the combination of
    /// applicationLabel/applicationTag/keyType/keySizeInBits/effectiveKeySize/
    /// keyClass — `kSecAttrLabel` is NOT part of it. Putting the display name
    /// there (as ENC-78 step 2 originally proposed) would make two keys named
    /// `encamera_default_key` collide with errSecDuplicateItem, which is the
    /// exact thing this ticket exists to fix. `kSecAttrLabel` gets the
    /// fingerprint too because the in-memory test wrapper keys its uniqueness
    /// off label; writing both keeps real and fake keychains in agreement.
    var keychainIdentityAttributes: [String: Any] {
        [
            kSecAttrLabel as String: keychainLabel.data(using: .utf8)!,
            kSecAttrApplicationLabel as String: keychainLabel.data(using: .utf8)!,
            kSecAttrApplicationTag as String: applicationTagValue.data(using: .utf8)!,
        ]
    }

    var keychainQueryDictForUpdate: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrCreationDate as String: creationDate,
        ]
        query.merge(keychainIdentityAttributes) { current, _ in current }
        return query
    }

    var keychainQueryDictForKeychain: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrCreationDate as String: creationDate,
            kSecValueData as String: keyData,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        query.merge(keychainIdentityAttributes) { current, _ in current }
        return query
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

// Added Helper extension for UUID to Data conversion
extension UUID {
    var data: Data {
        withUnsafeBytes(of: self.uuid) { Data($0) }
    }
}
