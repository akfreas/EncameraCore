//
//  File.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import UIKit
import Combine
import Sodium

enum DemoError: Error {
    case general
}

public class DemoFileEnumerator: FileAccess {
    public var directoryModel: DataStorageModel? = DemoDirectoryModel()
    
   
    
    public static var shared = DemoFileEnumerator()
    
    public required init() {
        
        Task {
            mediaList = await enumerateMedia()
            
        }
    }
    
    public func configure(with key: PrivateKey?, storageSettingsManager: DataStorageSetting) async {
        
    }
    
    
    public func copy(media: EncryptedMedia) async throws {
        
    }
    
    public func move(media: EncryptedMedia) async throws {
        
    }
    private var mediaList: [EncryptedMedia] = []
    
    public func createPreview<T>(for media: T) async throws -> PreviewModel where T : MediaDescribing {

        return PreviewModel(thumbnailMedia: CleartextMedia(source: Data(), mediaType: .preview, id: "sdf"))
    }
    func loadThumbnails<T>(for: DataStorageModel) async -> [T] where T : MediaDescribing, T.MediaSource == Data {
        []
    }
    
    public func deleteMediaForKey() async throws {
        
    }
    
    public func moveAllMedia(for keyName: KeyName, toRenamedKey newKeyName: KeyName) async throws {
        
    }
    
    public func loadMediaToURL<T>(media: T, progress: (Double) -> Void) async throws -> CleartextMedia<URL> where T : MediaDescribing {

        CleartextMedia(source: URL(fileURLWithPath: ""))
    }
    
    public static func withUrl() -> CleartextMedia<URL> {
        guard let url = Bundle.main
            .url(forResource: "3", withExtension: "JPG") else {
            fatalError()
        }
        return CleartextMedia(source: url)
    }
    
    public static var media: [CleartextMedia<URL>] {
        (1..<6).map { i in
            guard let url = Bundle.main
                .url(forResource: "\(i)", withExtension: "JPG") else {
                fatalError()
            }
            return CleartextMedia(source: url)

        }
    }
    
    public func withUrl() -> CleartextMedia<URL> {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: "dog", withExtension: "jpg") else {
            fatalError()
        }
        return CleartextMedia(source: url)
    }
    
    public func data() -> CleartextMedia<Data> {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: "dog", withExtension: "jpg"), let data = try? Data(contentsOf: url) else {
            return CleartextMedia(source: Data())
        }
        return CleartextMedia(source: data)

    }
    
    public func loadMediaInMemory<T>(media: T, progress: (Double) -> Void) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        return data()

    }
    
    public func save<T>(media: CleartextMedia<T>, progress: @escaping (Double) -> Void) async throws -> EncryptedMedia? where T : MediaSourcing {
        EncryptedMedia(source: URL(fileURLWithPath: ""), mediaType: .photo, id: "1234")
    }
    
    public func loadMediaPreview<T: MediaDescribing>(for media: T) async -> PreviewModel {
        guard let source = media.source as? URL,
              let data = try? Data(contentsOf: source) else {
            return try! PreviewModel(source: CleartextMedia(source: Data()))
        }
        let cleartext = CleartextMedia<Data>(source: data)
        let preview = PreviewModel(thumbnailMedia: cleartext)
        return preview
    }
    
    func createTempURL(for mediaType: MediaType, id: String) -> URL {
        return URL(fileURLWithPath: "")
    }

    
    
    typealias MediaTypeHandling = Data
    

    
    
    
    public func enumerateMedia<T>() async -> [T] where T : MediaDescribing, T.MediaSource == URL {
        let retVal: [T] = (1...6).map { val in
            let url = Bundle(for: type(of: self)).url(forResource: "\(val)", withExtension: "JPG")!
            return T(source: url, mediaType: .photo, id: "\(val)")
//            if let url = Bundle(for: type(of: self)).url(forResource: "\(val)", withExtension: "JPG")! {
//                return T(source: url, mediaType: .photo, id: "\(val)")
//            }
//            return nil
        }
        print("Enumerated images: \(retVal)")
        return retVal.compactMap({$0}).shuffled()
    }
    public func delete(media: EncryptedMedia) async throws {
        
    }
    public func deleteAllMedia() async throws {
        
    }
    
    public func loadLeadingThumbnail() async throws -> UIImage? {
        return UIImage(named: "dog")
    }
}

public class DemoDirectoryModel: DataStorageModel {
    public var storageType: StorageType = .local
    
    public var keyName: KeyName = "testSuite"
    
    public var baseURL: URL
    
    public var thumbnailDirectory: URL
    
    public required init(keyName: KeyName) {
        self.baseURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).appendingPathComponent("base")
        self.thumbnailDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                      isDirectory: true).appendingPathComponent("thumbs")
    }
    
    convenience init() {
        self.init(keyName: "")
    }
    
    
    func deleteAllFiles() throws {
       try  [baseURL, thumbnailDirectory].forEach { url in
            guard let enumerator = FileManager.default.enumerator(atPath: url.path) else {
                return
            }
            try enumerator.compactMap { item in
                guard let itemUrl = item as? URL else {
                    return nil
                }
                return itemUrl
            }
            .forEach { (file: URL) in
                try FileManager.default.removeItem(at: file)
                debugPrint("Deleted file at \(file)")
            }
        }
    }
        
}

public class DemoKeyManager: KeyManager {
   
    
    public var keyDirectoryStorage: DataStorageSetting = DemoStorageSettingsManager()
    
     
    
    private var hasExistingPassword = false
    public var throwError = false
    public var password: String? {
        didSet {
            hasExistingPassword = password != nil
        }
    }
    
    
    public func createBackupDocument() throws -> String {
        return ""
    }
    public func passwordExists() -> Bool {
        return hasExistingPassword
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
    
    public func save(key: PrivateKey, storageType: StorageType, setNewKeyToCurrent: Bool, backupToiCloud: Bool) throws {
        
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
    
    public func generateNewKey(name: String, storageType: StorageType, backupToiCloud: Bool) throws -> PrivateKey {
        return try PrivateKey(base64String: "")
    }
    
    public func storedKeys() throws -> [PrivateKey] {
        return storedKeysValue
    }
    
    public func validateKeyName(name: String) throws {
        
    }
    
    
    public convenience init() {
        self.init(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())
    }
    
    public convenience init(keys: [PrivateKey]) {
        self.init(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())
        self.storedKeysValue = keys
    }
    
    public required init(isAuthenticated: AnyPublisher<Bool, Never>, keyDirectoryStorage: DataStorageSetting) {
        self.isAuthenticated = isAuthenticated
        self.currentKey = PrivateKey(name: "secrets", keyBytes: [], creationDate: Date())
        self.keyPublisher = PassthroughSubject<PrivateKey?, Never>().eraseToAnyPublisher()
    }
    
    public var isAuthenticated: AnyPublisher<Bool, Never>
        
    public var keyPublisher: AnyPublisher<PrivateKey?, Never>
    
    public func clearKeychainData() {
        
    }
    
    func generateNewKey(name: String) throws {
        
    }
    
    func validatePasswordPair(_ password1: String, password2: String) -> PasswordValidation {
        return .valid
    }
}

public class DemoOnboardingManager: OnboardingManaging {
    required public init(keyManager: KeyManager, authManager: AuthManager, settingsManager: SettingsManager) {
        
    }
    
    public func generateOnboardingFlow() -> [OnboardingFlowScreen] {
        return [.intro, .dataStorageSetting]
    }
    
    public func saveOnboardingState(_ state: OnboardingState, settings: SavedSettings) async throws {
        
    }
    
    
}

public class DemoStorageSettingsManager: DataStorageSetting {
    public init() {}
    public func storageModelFor(keyName: KeyName?) -> DataStorageModel? {
        return LocalStorageModel(keyName: keyName!)
    }
    
    public func setStorageTypeFor(keyName: KeyName, directoryModelType: StorageType) {
        
    }
    
    
}

public class DemoPrivateKey {
    public static func dummyKey(name: String) -> PrivateKey {
        let hash: Array<UInt8> = Sodium().secretStream.xchacha20poly1305.key()
        let dateComponents = DateComponents(timeZone: TimeZone(identifier: "Europe/Berlin"), year: 2022, month: Int.random(in: 1..<12), day: Int.random(in: 1..<28), hour: Int.random(in: 1..<11), minute: 0, second: 0)
        let date = Calendar(identifier: .gregorian).date(from: dateComponents)
        print("date", date!)
        return PrivateKey(name: name, keyBytes: hash, creationDate: date!)
    }
    
    public static func dummyKey() -> PrivateKey {
        let hash: Array<UInt8> = [36,97,114,103,111,110,50,105,100,36,118,61,49,57,36,109,61,54,53,53,51,54,44,116,61,50,44,112,61,49,36,76,122,73,48,78,103,67,57,90,69,89,76,81,80,70,76,85,49,69,80,119,65,36,83,66,66,49,65,85,86,74,55,82,85,90,116,79,67,111,104,82,100,89,67,71,57,114,90,119,109,81,47,118,74,77,121,48,85,71,108,69,103,66,122,79,77]
        let dateComponents = DateComponents(timeZone: TimeZone(identifier: "Europe/Berlin"), year: 2022, month: 2, day: 9, hour: 5, minute: 0, second: 0)
        let date = Calendar(identifier: .gregorian).date(from: dateComponents)
        
        return PrivateKey(name: "test", keyBytes: hash, creationDate: date ?? Date())
    }
}

public class DemoPurchasedPermissionManaging: PurchasedPermissionManaging {
    
    public init() {}
    func requestProducts() async {
        
    }
    
    public func isAllowedAccess(feature: AppFeature) -> Bool {
        return false
    }
    
    func beginPurchase(for feature: EncameraSubscription) async {
        
    }
    public func hasEntitlement() -> Bool {
        return false
    }
}
