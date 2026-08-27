import Foundation
import Combine

public class DemoAlbumManager: AlbumManaging {
    public var keyManager: any KeyManager
    
    public func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {
        
    }
    
    public func removeAlbumCover(album: Album) {
        
    }
    
    public func resetAlbumCover(album: Album) {
        
    }
    
    public func getAlbumCoverImageId(album: Album) -> String? {
        return nil
    }
    
    public func isAlbumCoverImageDisabled(album: Album) -> Bool {
        return false
    }
    
    public func isAlbumHidden(_ album: Album) -> Bool {
        return false
    }
    
    public func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album) {

    }
    
    public func renameAlbum(album: Album, to newName: String) throws -> Album {
        return Album(name: "Name", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey())
    }

    public func albumMediaCount(album: Album) -> Int {
        return 12
    }

    public var currentAlbumMediaCount: Int? {
        return 23
    }

    public var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> = PassthroughSubject<AlbumOperation, Never>().eraseToAnyPublisher()

    @discardableResult public func create(name: String, storageOption: StorageType) throws -> Album {
        return Album(name: "Name", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey())
    }

    private var demoAlbums: [Album]

    public func fetchAlbumsFromSources(includingHidden _: Bool) -> [Album] {
        demoAlbums
    }

    public func restoreCurrentAlbumFromUserDefaults() {
        currentAlbum = demoAlbums.first
    }

    public var albumPublisher: AnyPublisher<[Album], Never> {
        albumSubject.eraseToAnyPublisher()
    }

    public var selectedAlbumPublisher: AnyPublisher<Album?, Never> = PassthroughSubject<Album?, Never>().eraseToAnyPublisher()

    private var albumSubject = PassthroughSubject<[Album], Never>()


    public var lockedAlbums: [LockedAlbumPlaceholder] = []

    public var defaultStorageForAlbum: StorageType
    public var currentAlbum: Album?

    public required init(keyManager: KeyManager = DemoKeyManager(), syncedDataStore: SyncedDataStore? = nil) {
        // Initialize demo data
        self.defaultStorageForAlbum = .local // Example storage type
        let key = DemoPrivateKey.dummyKey()
        self.demoAlbums = [
            // Populate with demo albums
            Album(name: "Personal", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Private", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Secret", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Hidden", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Demo Album 5", storageOption: .local, creationDate: Date(), key: key),
            Album(name: "Demo Album 6", storageOption: .local, creationDate: Date(), key: key),
        ]
        self.keyManager = DemoKeyManager()
        self.currentAlbum = demoAlbums.first
        // Note: syncedDataStore is ignored in demo implementation
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
