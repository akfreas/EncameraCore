import Foundation
import Combine

public class DemoKeyManager: KeyManager {
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


    public func setOrUpdatePassword(_ password: String) throws {

    }

    public func createBackupDocument() throws -> String {
        return ""
    }
    public func retrieveKeyPassphrase() throws -> [String] {
        return ["your", "cool", "cat"]
    }
    public func passwordExists() -> Bool {
        return hasExistingPassword
    }
    public func generateKeyUsingRandomWords(name: String) throws -> PrivateKey {
        return DemoPrivateKey.dummyKey()
    }
    public func moveAllKeysToiCloud() throws {

    }
    @discardableResult public func generateKeyFromPasswordComponents(_ components: [String], name: String) throws -> PrivateKey {
        return DemoPrivateKey.dummyKey()
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

    public func save(key: PrivateKey, setNewKeyToCurrent: Bool, backupToiCloud: Bool) throws {

    }

    public func update(key: PrivateKey, backupToiCloud: Bool) throws {

    }

    public var currentKey: PrivateKey?

    public func setActiveKey(_ name: KeyName?) throws {

    }


    public var storedKeysValue: [PrivateKey] = []

    func deleteKey(by name: KeyName) throws {

    }

    func setActiveKey(_ name: KeyName) throws {

    }

    public func generateNewKey(name: String, backupToiCloud: Bool) throws -> PrivateKey {
        return try PrivateKey(base64String: "")
    }

    public func storedKeys() throws -> [PrivateKey] {
        return storedKeysValue
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

    public required init(isAuthenticated: AnyPublisher<Bool, Never>) {
        self.isAuthenticated = isAuthenticated
        self.currentKey = PrivateKey(name: "secrets", keyBytes: [], creationDate: Date())
        self.keyPublisher = PassthroughSubject<PrivateKey?, Never>().eraseToAnyPublisher()
    }

    public var isAuthenticated: AnyPublisher<Bool, Never>

    public func clearKeychainData() {

    }

    func generateNewKey(name: String) throws {

    }

    func validatePasswordPair(_ password1: String, password2: String) -> PasswordValidation {
        return .valid
    }
}
