import Foundation
import Combine

public class DemoAlbumManager: AlbumManaging {
    public func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {
        
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
