//  Created by Alexander Freas on 12.11.23.
//

import Foundation
import Combine

public enum AlbumError: Error, CustomStringConvertible {
    case albumNameError
    case albumExists
    case albumNotFoundAtSourceLocation
    case noCurrentKeySet

    public var description: String {
        switch self {
        case .albumNameError:
            return L10n.albumNameInvalid
        case .albumExists:
            return L10n.aKeyWithThisNameAlreadyExists
        case .albumNotFoundAtSourceLocation:
            return L10n.albumNotFoundAtSourceLocation
        case .noCurrentKeySet:
            return L10n.noKeyAvailable
        }
    }
}

public enum AlbumOperation {
    case selectedAlbumChanged(album: Album?)
    case albumsUpdated(albums: [Album])
    case albumMoved(album: Album)
    case albumDeleted(album: Album)
    case albumRenamed(album: Album)
    case albumCreated(album: Album)
}

public class AlbumManager: AlbumManaging, ObservableObject {

    public var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> {
        albumOperationSubject.eraseToAnyPublisher()
    }

    private var albumOperationSubject: PassthroughSubject<AlbumOperation, Never> = PassthroughSubject()

    @Published public var albums: [Album] = [] {
        didSet {
            albumOperationSubject.send(.albumsUpdated(albums: albums))
        }
    }

    @Published public var currentAlbum: Album? {
        didSet {
            albumOperationSubject.send(.selectedAlbumChanged(album: currentAlbum))
            UserDefaultUtils.set(currentAlbum?.id, forKey: .currentAlbumID)
        }
    }

    public var currentAlbumMediaCount: Int? {
        guard let currentAlbum else {
            return nil
        }
        return albumMediaCount(album: currentAlbum)
    }

    public var defaultStorageForAlbum: StorageType {
        didSet {
            UserDefaultUtils.set(defaultStorageForAlbum.rawValue, forKey: .defaultStorageLocation)
        }
    }

    private var keyManager: KeyManager

    private var albumSet: Set<Album> = [] {
        didSet {
            albums = Array(albumSet).filter({ album in
                !UserDefaultUtils.bool(forKey: .isAlbumHidden(name: album.name))
            }).sorted(by: { $0.creationDate < $1.creationDate })
        }
    }

    public func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album) {
        UserDefaultUtils.set(isAlbumHidden, forKey: .isAlbumHidden(name: album.name))
        loadAlbumsFromFilesystem()
    }

    public func isAlbumHidden(_ album: Album) -> Bool {
        UserDefaultUtils.bool(forKey: .isAlbumHidden(name: album.name))
    }

    public func loadAlbumsFromFilesystem() {

        let fileManager = FileManager.default
        let mapToAlbum: (URL, StorageType) -> Album? = { url, storageType in
            let directoryName = url.lastPathComponent
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let creationDate = attributes?[.creationDate] as? Date

            if let creationDate {
                return self.matchAlbumToKeyIfNeeded(albumName: directoryName, storageType: storageType, creationDate: creationDate)
            } else {
                return nil
            }
        }

        let localAlbums = LocalStorageModel.enumerateRootDirectory()
            .compactMap { url -> Album? in
                return mapToAlbum(url, .local)
            }
        var iCloudAlbums: [Album] = []
        if DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) == .available {
            iCloudAlbums = iCloudStorageModel.enumerateRootDirectory()
                .compactMap { url -> Album? in
                    return mapToAlbum(url, .icloud)
                }
        }
        self.albumSet = Set(localAlbums).union(Set(iCloudAlbums))
        // Retrieve the current album ID from user defaults
        if let currentAlbumID = UserDefaultUtils.string(forKey: .currentAlbumID),
            let foundAlbum = albumSet.first(where: { $0.id == currentAlbumID }) {
            // Find the album with the matching ID
            self.currentAlbum = foundAlbum
        } else {
            self.currentAlbum = albumSet.first
        }
    }

    required public init(keyManager: KeyManager) {
        self.keyManager = keyManager
        if let defaultStorageLocationValue = UserDefaultUtils.string(forKey: .defaultStorageLocation),
           let defaultStorageLocation = StorageType(rawValue: defaultStorageLocationValue) {
            self.defaultStorageForAlbum = defaultStorageLocation
        } else {
            self.defaultStorageForAlbum = .local
        }

        loadAlbumsFromFilesystem()
    }

    public func delete(album: Album) {
        let fileManager = FileManager.default
        let albumURL = album.storageURL

        // Check if the directory exists
        if fileManager.fileExists(atPath: albumURL.path) {
            // If the directory exists, delete it
            try? fileManager.removeItem(at: albumURL)
        }

        // Remove album from albums collection
        albumSet.remove(album)
        albumOperationSubject.send(.albumDeleted(album: album))
        if albumSet.count == 0 {
            currentAlbum = try? create(name: AppConstants.defaultAlbumName, storageOption: .local)
        } else {
            currentAlbum = albumSet.first
        }
    }


    public func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {
        UserDefaultUtils.set(image.id, forKey: .albumCoverImage(albumName: album.name))
    }

    @discardableResult public func create(name: String, storageOption: StorageType) throws -> Album  {
        guard let currentKey = keyManager.currentKey else {
            throw AlbumError.noCurrentKeySet
        }

        if let existingAlbum = albumSet.first(where: { $0.name == name }) {
            return existingAlbum
        }

        let album = Album(name: name, storageOption: storageOption, creationDate: Date(), key: currentKey)
        debugPrint("Starting album creation process")

        let fileManager = FileManager.default
        let albumURL = album.storageURL

        debugPrint("File manager and album URL are set up")

        defer {
            // Add album to the albums collection
            debugPrint("Adding album to the collection")
            albumSet.insert(album)
            albumOperationSubject.send(.albumCreated(album: album))
        }

        // Check if the directory already exists
        debugPrint("Checking if the directory exists at path: \(albumURL.path)")
        if fileManager.fileExists(atPath: albumURL.path) {
            // If the directory exists, throw the albumExists error
            debugPrint("Directory already exists, throwing albumExists error")
            throw AlbumError.albumExists
        }

        debugPrint("Directory does not exist, proceeding to create it")

        // If the directory does not exist, create it
        try fileManager.createDirectory(
            at: albumURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        debugPrint("Directory created successfully")
        return album
    }

    
    public func moveAlbum(album: Album, toStorage: StorageType) throws -> Album {
        let fileManager = FileManager.default
        let currentStorage = album.storageOption.modelForType.init(album: album)
        if toStorage == .icloud {
            try? self.keyManager.backupKeychainToiCloud(backupEnabled: true)
        }
        debugPrint("Starting the move process for album: \(album.name)")

        // Determine the new storage URL based on the destination storage type
        let newStorage: DataStorageModel = toStorage == .local ? LocalStorageModel(album: album) : iCloudStorageModel(album: album)

        debugPrint("Current storage URL: \(currentStorage.baseURL)")
        debugPrint("New storage URL: \(newStorage.baseURL)")

        // Check if the album exists at the current location
        guard fileManager.fileExists(atPath: currentStorage.baseURL.path) else {
            debugPrint("Album not found at the source location.")
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        // Ensure the destination directory exists
        if !fileManager.fileExists(atPath: newStorage.baseURL.path) {
            debugPrint("Destination directory does not exist. Creating new directory.")
            try fileManager.createDirectory(at: newStorage.baseURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Move files individually to merge contents
        let enumerator = fileManager.enumerator(at: currentStorage.baseURL, includingPropertiesForKeys: nil)
        while let sourceURL = enumerator?.nextObject() as? URL {
            let destinationURL = newStorage.baseURL.appendingPathComponent(sourceURL.lastPathComponent)

            if fileManager.fileExists(atPath: destinationURL.path) {
                debugPrint("File already exists at destination: \(destinationURL.path). Implementing merge logic.")
                // Implement your logic for handling duplicate files
            } else {
                debugPrint("Moving file from \(sourceURL.path) to \(destinationURL.path)")
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        // Delete the source directory if it's empty
        if let contents = try? fileManager.contentsOfDirectory(atPath: currentStorage.baseURL.path), contents.isEmpty {
            debugPrint("Source directory is empty after moving files. Deleting source directory.")
            try fileManager.removeItem(at: currentStorage.baseURL)
        }

        // Update the album's storage option and URL if needed
        if var movedAlbum = albums.first(where: { $0.id == album.id }) {
            movedAlbum.storageOption = toStorage
            albumSet.insert(movedAlbum)
            albumOperationSubject.send(.albumMoved(album: movedAlbum))
            debugPrint("Updated album storage option for \(album.name)")
            return movedAlbum
            // Update the storageURL if your Album model has this property
        } else {
            debugPrint("Could not update album, not found in the albums collection.")
        }


        debugPrint("Completed the move process for album: \(album.name)")
        return album
    }

    public func renameAlbum(album: Album, to newName: String) throws -> Album {
        // Validate the new name
        try validateAlbumName(name: newName)

        // Check if an album with the new name already exists
        if albumSet.contains(where: { $0.name == newName }) {
            throw AlbumError.albumExists
        }
        guard var albumToUpdate = albumSet.first(where: { $0.id == album.id }) else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }
        
        albumToUpdate.name = newName
        // Rename the album in the file system
        let fileManager = FileManager.default
        let oldURL = album.storageURL
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(albumToUpdate.encryptedPathComponent)

        if fileManager.fileExists(atPath: oldURL.path) {
            try fileManager.moveItem(at: oldURL, to: newURL)
        } else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        albumSet.remove(album)
        albumSet.insert(albumToUpdate)
        albumOperationSubject.send(.albumRenamed(album: albumToUpdate))
        if currentAlbum?.id == album.id {
            currentAlbum = albumToUpdate
        }
        return albumToUpdate
    }



    public func storageModel(for album: Album) -> DataStorageModel? {
        albumSet.first(where: { albumInSet in
            albumInSet.id == album.id
        })?.storageOption.modelForType.init(album: album)
    }

    public func validateAlbumName(name: String) throws {
        guard name.count > 0 else {
            throw KeyManagerError.keyNameError
        }
    }

    public func albumMediaCount(album: Album) -> Int {
        let storageModel = storageModel(for: album)
        return storageModel?.countOfFiles(matchingFileExtension: [MediaType.photo.encryptedFileExtension, MediaType.video.encryptedFileExtension]) ?? 0
    }

    private func matchAlbumToKeyIfNeeded(albumName: String, storageType: StorageType, creationDate: Date) -> Album? {
        let key = keyManager.keyWith(name: albumName)
        if let key {
            return Album(encryptedName: albumName, storageOption: storageType, creationDate: creationDate, key: key)
        } else if let key = keyManager.currentKey {
            return Album(encryptedName: albumName, storageOption: storageType, creationDate: creationDate, key: key)
        } else {
            return nil
        }
    }
}
