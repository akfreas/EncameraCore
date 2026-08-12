import Foundation
import Combine
import Sodium

public class DemoKeyManager: KeyManager {
    public func getAuthenticationConfiguration() -> AuthenticationConfiguration? {
        return AuthenticationConfiguration(enabledTypes: [.passcode(.password)])
    }

    public func setAuthenticationConfiguration(config: AuthenticationConfiguration) throws {

    }

    private var multiDeviceState: MultiDeviceState?

    public func getMultiDeviceState() -> MultiDeviceState? {
        multiDeviceState
    }

    public func setMultiDeviceState(_ state: MultiDeviceState) throws {
        multiDeviceState = MultiDeviceState.merging(existing: multiDeviceState, incoming: state)
    }

    public func overwriteMultiDeviceState(_ state: MultiDeviceState) throws {
        multiDeviceState = state
    }

    public var isSyncEnabled: Bool = false
    
    public func setPassword(_ password: String, type: PasscodeType) throws {

    }
    
    public func setOrUpdatePassword(_ password: String, type: PasscodeType) throws {

    }
    
    public func changePassword(newPassword: String, existingPassword: String, type: PasscodeType) throws {
        
    }
    
    /// Settable so previews and tests can stand up a biometrics-only account
    /// (`.none`), which is the configuration the real KeychainManager reports
    /// whenever no password hash exists.
    public var passcodeType: PasscodeType = .pinCode(length: AppConstants.defaultPinCodeLength)


    public func clearPassword() throws {

    }

    public func dumpAllKeychainEntries() -> [KeychainDumpEntry] {
        [
            KeychainDumpEntry(
                itemClass: "Generic Password",
                displayName: "encamera",
                isSynchronizable: true,
                attributes: [
                    KeychainDumpAttribute(label: "Account", rawKey: "acct", value: "encamera"),
                    KeychainDumpAttribute(label: "iCloud Sync", rawKey: "sync", value: "Yes"),
                    KeychainDumpAttribute(label: "Value Data", rawKey: "v_Data", value: "$argon2id$…  (96 bytes)")
                ]
            ),
            KeychainDumpEntry(
                itemClass: "Key",
                displayName: AppConstants.defaultKeyName,
                isSynchronizable: true,
                attributes: [
                    KeychainDumpAttribute(label: "Label", rawKey: "labl", value: AppConstants.defaultKeyName),
                    KeychainDumpAttribute(label: "iCloud Sync", rawKey: "sync", value: "Yes"),
                    KeychainDumpAttribute(label: "Value Data", rawKey: "v_Data", value: "0x…  (32 bytes)")
                ]
            )
        ]
    }

    public var keyPublisher: AnyPublisher<PrivateKey?, Never>


    private var hasExistingPassword = false
    public var throwError = false
    public var password: String? {
        didSet {
            hasExistingPassword = password != nil
        }
    }

    public func keyWith(name: String) -> PrivateKey? {
        return nil
    }

    public func keyWith(uuid: UUID) -> PrivateKey? {
        return storedKeysValue.first(where: { $0.uuid == uuid })
    }
    public func getPasswordHash() throws -> Data {
        return Data()
    }

    public func setPasswordHash(hash: Data) throws {

    }

    public func setOrUpdatePassword(_ password: String) throws {

    }

    public func createBackupDocument() throws -> String {
        return ""
    }
    public func retrieveKeyPassphrase() throws -> KeyPassphrase {
        return KeyPassphrase(words: ["your", "cool", "cat"])
    }
    public func passwordExists() -> Bool {
        return hasExistingPassword
    }
    public func credentialSnapshot() -> KeychainCredentialSnapshot {
        return KeychainCredentialSnapshot(
            passwordExists: hasExistingPassword,
            passphraseExists: true,
            defaultKeyExists: !storedKeysValue.isEmpty,
            backupFlagState: .notSet
        )
    }
    public func generateKeyUsingRandomWords(name: String) throws -> PrivateKey {
        return DemoPrivateKey.dummyKey()
    }
    
    public func backupKeychainToiCloud(backupEnabled: Bool) throws {
        // Record the flip so tests can assert that a code path did (or, more often,
        // did not) change the key sync setting behind the user's back.
        if let backupError {
            throw backupError
        }
        isSyncEnabled = backupEnabled
    }

    /// Set to make the next flip fail, so callers' error handling is testable.
    public var backupError: KeyManagerError?

    /// Set to stage a conflict for the confirmation copy.
    public var stagedKeyConflict: MultiDeviceKeyConflict?

    public func enableMultiDeviceMode() throws {
        try backupKeychainToiCloud(backupEnabled: true)
    }

    public func multiDeviceKeyConflict() -> MultiDeviceKeyConflict? {
        stagedKeyConflict
    }
    @discardableResult public func generateKeyFromPasswordComponentsAndSave(_ components: [String], name: String) throws -> PrivateKey {
        return DemoPrivateKey.dummyKey()
    }

    public func saveKeyWithPassphrase(passphrase: KeyPassphrase) throws -> PrivateKey {
        return DemoPrivateKey.dummyKey()
    }

    @discardableResult public func restoreDefaultKeyFromPassphraseIfNeeded() throws -> Bool {
        return false
    }

    func validate(password: String) -> PasswordValidation {
        return .valid
    }

    public func changePassword(newPassword: String, existingPassword: String) throws {

    }

    public func checkPassword(_ password: String) throws -> Bool {
        if self.password != password {
            throw KeyManagerError.invalidPassword
        }
        return self.password == password
    }

    public func setPassword(_ password: String) throws {
        self.password = password
    }

    public func deleteKey(_ key: PrivateKey) throws {

    }

    /// Deduplicates on key material (never display name — every production key
    /// is `encamera_default_key`), mirroring `KeychainManager.save`. Honors
    /// `setNewKeyToCurrent` so a test can prove a decrypt-only add does not
    /// repoint which key new media is written with.
    public func save(key: PrivateKey, setNewKeyToCurrent: Bool) throws {
        if !storedKeysValue.contains(where: { $0.keyBytes == key.keyBytes }) {
            storedKeysValue.append(key)
        }
        if setNewKeyToCurrent {
            currentKey = key
        }
    }

    /// Deterministic stand-in for Argon2 derivation: distinct phrases yield
    /// distinct keys and the same phrase always yields the same key, which is
    /// all a fingerprint-gating test needs, without the pwHash cost.
    public func deriveKey(from components: [String], name: String) throws -> PrivateKey {
        guard !components.isEmpty else {
            throw KeyManagerError.invalidInput
        }
        let material = Array(components.joined(separator: "-").utf8)
        guard let bytes = Sodium().genericHash.hash(message: material, outputLength: 32) else {
            throw KeyManagerError.keyDerivationFailed
        }
        return PrivateKey(name: name, keyBytes: bytes, creationDate: Date(timeIntervalSince1970: 0))
    }

    public func update(key: PrivateKey) throws {

    }

    public var currentKey: PrivateKey?

    public func setActiveKey(_ name: KeyName?) throws {

    }


    public var storedKeysValue: [PrivateKey] = []

    func deleteKey(by name: KeyName) throws {

    }

    func setActiveKey(_ name: KeyName) throws {

    }

    public func generateNewKey(name: String) throws -> PrivateKey {
        return try PrivateKey(base64String: "")
    }

    public func storedKeys() throws -> [PrivateKey] {
        return storedKeysValue
    }

    public func deleteKey(fingerprint: String, scope: KeyDeletionScope) throws {
        storedKeysValue.removeAll { $0.keychainLabel == fingerprint }
    }

    public func validateKeyName(name: String) throws {

    }


    public convenience init() {
        self.init(isAuthenticated: Just(true).eraseToAnyPublisher())
    }

    public convenience init(keys: [PrivateKey]) {
        self.init(isAuthenticated: Just(true).eraseToAnyPublisher())
        self.storedKeysValue = keys
    }

    public required init(isAuthenticated: AnyPublisher<Bool, Never>, keychainWrapper: KeychainWrapperProtocol = KeychainWrapper()) {
        self.isAuthenticated = isAuthenticated
        self.currentKey = PrivateKey(name: "secrets", keyBytes: [], creationDate: Date())
        self.keyPublisher = PassthroughSubject<PrivateKey?, Never>().eraseToAnyPublisher()
    }

    public var isAuthenticated: AnyPublisher<Bool, Never>

    public func clearKeychainData(scope: KeyDeletionScope) {

    }

    public func residualKeychainItemNames() -> [String] { [] }

    func generateNewKey(name: String) throws {

    }

    func validatePasswordPair(_ password1: String, password2: String) -> PasswordValidation {
        return .valid
    }
}
