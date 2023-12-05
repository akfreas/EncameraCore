//
//  File.swift
//
//
//  Created by Alexander Freas on 12.11.23.
//

import Foundation
import Combine

public enum AlbumError: Error, CustomStringConvertible {
    case albumNameError
    case albumExists
    case albumNotFoundAtSourceLocation

    public var description: String {
        switch self {
        case .albumNameError:
            return L10n.albumNameInvalid
        case .albumExists:
            return L10n.aKeyWithThisNameAlreadyExists
        case .albumNotFoundAtSourceLocation:
            return L10n.albumNotFoundAtSourceLocation
        }
    }
}

public class AlbumManager: AlbumManaging, ObservableObject {



    public var selectedAlbumPublisher: AnyPublisher<Album?, Never> {
        $currentAlbum.eraseToAnyPublisher()
    }


    @Published public var albums: [Album] = [] {
        didSet {
            albumSubject.send(albums)
        }
    }

    public var albumPublisher: AnyPublisher<[Album], Never> {
        albumSubject.eraseToAnyPublisher()
    }

    public var defaultStorageForAlbum: StorageType = .local

    private var albumSubject: PassthroughSubject<[Album], Never> = .init()
    private var albumSet: Set<Album> = [] {
        didSet {
            albums = Array(albumSet).sorted(by: { $0.creationDate < $1.creationDate })
        }
    }
    @Published public var currentAlbum: Album? {
        didSet {
            UserDefaultUtils.set(currentAlbum?.id, forKey: .currentAlbumID)
        }
    }
    private func loadAvailableAlbums() {
        let fileManager = FileManager.default

        let localAlbums = LocalStorageModel.enumerateRootDirectory()
            .compactMap { url -> Album? in
                let directoryName = url.lastPathComponent
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let creationDate = attributes?[.creationDate] as? Date
                return creationDate != nil ? Album(name: directoryName, storageOption: .local, creationDate: creationDate!) : nil
            }
        var iCloudAlbums: [Album] = []
        if DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) == .available {
            iCloudAlbums = iCloudStorageModel.enumerateRootDirectory()
                .compactMap { url -> Album? in
                    let directoryName = url.lastPathComponent
                    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                    let creationDate = attributes?[.creationDate] as? Date

                    return creationDate != nil ? Album(name: directoryName, storageOption: .icloud, creationDate: creationDate!) : nil
                }
        }
        self.albumSet = Set(localAlbums).union(Set(iCloudAlbums))

    }

    required public init() {

        loadAvailableAlbums()
        // Retrieve the current album ID from user defaults
        if let currentAlbumID = UserDefaultUtils.string(forKey: .currentAlbumID),
            let foundAlbum = albumSet.first(where: { $0.id == currentAlbumID }) {
            // Find the album with the matching ID
            self.currentAlbum = foundAlbum
        } else {
            self.currentAlbum = albumSet.first
        }
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
    }

    public func create(album: Album) throws {
        debugPrint("Starting album creation process")

        let fileManager = FileManager.default
        let albumURL = album.storageURL

        debugPrint("File manager and album URL are set up")

        defer {
            // Add album to the albums collection
            debugPrint("Adding album to the collection")
            albumSet.insert(album)
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
    }


    public func moveAlbum(album: Album, toStorage: StorageType) throws {
        let fileManager = FileManager.default
        let currentStorage = album.storageOption.modelForType.init(album: album)

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
            debugPrint("Updated album storage option for \(album.name)")
            // Update the storageURL if your Album model has this property
        } else {
            debugPrint("Could not update album, not found in the albums collection.")
        }

        debugPrint("Completed the move process for album: \(album.name)")
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


}
