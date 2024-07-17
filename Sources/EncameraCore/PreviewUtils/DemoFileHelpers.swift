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

    private var mediaList: [InteractableMedia<EncryptedMedia>] = []

    public static var shared = DemoFileEnumerator()

    public required init() {
        Task {
            mediaList = await enumerateMedia()
        }
    }

    public required init(for album: Album, albumManager: AlbumManaging) async {
        mediaList = await enumerateMedia()
    }

    public func configure(for album: Album, albumManager: AlbumManaging) async {
        // Implementation here
    }

    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        // Implementation here
    }

    public func move(media: InteractableMedia<EncryptedMedia>) async throws {
        // Implementation here
    }

    @discardableResult
    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        return PreviewModel(thumbnailMedia: CleartextMedia(source: .data(Data()), mediaType: .preview, id: "sdf"))
    }

    public func deleteMediaForKey() async throws {
        // Implementation here
    }

    public func deleteAllMedia() async throws {
        // Implementation here
    }

    public static func deleteThumbnailDirectory() throws {
        // Implementation here
    }

    public func loadMedia<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T : MediaDescribing {
        return try! InteractableMedia(underlyingMedia: [CleartextMedia(source: .url(URL(fileURLWithPath: "")))])
    }

    public func loadMediaInMemory(media: InteractableMedia<EncryptedMedia>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> {
        let cleartextMedia = CleartextMedia(source: Data())
        return try InteractableMedia(underlyingMedia: [cleartextMedia])
    }

    public func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        let encryptedMedia = EncryptedMedia(source: URL(fileURLWithPath: ""), mediaType: .photo, id: "1234")
        return try InteractableMedia(underlyingMedia: [encryptedMedia])
    }

    public func loadMediaPreview<T: MediaDescribing>(for media: InteractableMedia<T>) async throws -> PreviewModel {
        guard let source = media.photoURL,
              let data = try? Data(contentsOf: source) else {
            return try PreviewModel(source: CleartextMedia(source: Data()))
        }
        let cleartext = CleartextMedia(source: data)
        let preview = PreviewModel(thumbnailMedia: cleartext)
        return preview
    }

    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T : MediaDescribing {
        let retVal: [InteractableMedia<T>] = (7...11).compactMap { val in
            guard let url = Bundle(for: type(of: self)).url(forResource: "\(val)", withExtension: "jpg") else { return nil }
            return try? InteractableMedia(underlyingMedia: [T(source: .url(url), mediaType: .photo, id: "\(val)")])
        }.shuffled()
        return retVal
    }

    public func delete(media: InteractableMedia<EncryptedMedia>) async throws {
        // Implementation here
    }

    public func loadLeadingThumbnail() async throws -> UIImage? {
        guard let last = mediaList.popLast(), case .url(let source) = last.thumbnailSource.source else {
            return nil
        }
        return UIImage(data: try Data(contentsOf: source))
    }
}

public class DemoDirectoryModel: DataStorageModel {
    public static var rootURL: URL = URL(fileURLWithPath: "")
    

    public var storageType: StorageType = .local
    
    public var album: Album = Album(name: "Test", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey())

    public var baseURL: URL
    
    public var thumbnailDirectory: URL
    
    public required init(album: Album) {
        self.baseURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).appendingPathComponent("base")
        self.thumbnailDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                      isDirectory: true).appendingPathComponent("thumbs")
    }
    
    convenience init() {
        self.init(album: Album(name: "", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey()))
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

public class DemoOnboardingManager: OnboardingManaging {
    required public init(keyManager: KeyManager = DemoKeyManager(), authManager: AuthManager = DemoAuthManager(), settingsManager: SettingsManager = SettingsManager()) {
        
    }
    
    public func generateOnboardingFlow() -> [OnboardingFlowScreen] {
        return [.setPinCode]
    }
    
    public func saveOnboardingState(_ state: OnboardingState, settings: SavedSettings) async throws {
        
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

public class DemoAlbumManager: AlbumManaging {
    public func renameAlbum(album: Album, to newName: String) throws -> Album {
        return Album(name: "Name", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey())
    }
    
    public func albumMediaCount(album: Album) -> Int {
        return 12
    }

    public var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> = PassthroughSubject<AlbumOperation, Never>().eraseToAnyPublisher()

    @discardableResult public func create(name: String, storageOption: StorageType) throws -> Album {
        return Album(name: "Name", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey())
    }
    
    @Published public var albums: [Album]
    public func loadAlbumsFromFilesystem() {

    }

    public var albumPublisher: AnyPublisher<[Album], Never> {
        albumSubject.eraseToAnyPublisher()
    }

    public var selectedAlbumPublisher: AnyPublisher<Album?, Never> = PassthroughSubject<Album?, Never>().eraseToAnyPublisher()

    private var albumSubject = PassthroughSubject<[Album], Never>()


    public var defaultStorageForAlbum: StorageType
    public var currentAlbum: Album?

    public required init(keyManager: KeyManager = DemoKeyManager()) {
        // Initialize demo data
        self.defaultStorageForAlbum = .local // Example storage type
        let key = DemoPrivateKey.dummyKey()
        self.albums = [
            // Populate with demo albums
            Album(name: "Personal", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Private", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Secret", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Hidden", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Demo Album 5", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Demo Album 6", storageOption: .local, creationDate: Date(), key: key),
        ]
        self.currentAlbum = albums.first
    }

    public func delete(album: Album) {
        // No-op for demo
    }
    public func moveAlbum(album: Album, toStorage: StorageType) throws -> Album {
        fatalError()

    }
    public func create(album: Album) throws {
        // No-op for demo
    }

    public func storageModel(for album: Album) -> DataStorageModel? {
        // Return a demo storage model
        return LocalStorageModel(album: album)
    }

    public func validateAlbumName(name: String) throws {
        // Example validation logic
        guard !name.isEmpty else {
            throw AlbumError.albumNameError
        }
    }

}
