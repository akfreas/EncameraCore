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

    public var description: String {
        switch self {
        case .albumNameError:
            return L10n.albumNameInvalid
        case .albumExists:
            return L10n.aKeyWithThisNameAlreadyExists
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
    @Published public var currentAlbum: Album? {
        didSet {
            UserDefaultUtils.set(currentAlbum?.id, forKey: .currentAlbumID)
        }
    }
    public var availableAlbums: [Album] {
        let fileManager = FileManager.default

        let localAlbums = LocalStorageModel.enumerateRootDirectory()
            .compactMap { url -> Album? in
                let directoryName = url.lastPathComponent
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let creationDate = attributes?[.creationDate] as? Date
                print("name: \(url), creationDate: \(String(describing: creationDate))")
                return creationDate != nil ? Album(name: directoryName, storageOption: .local, creationDate: creationDate!) : nil
            }

        let iCloudAlbums = iCloudStorageModel.enumerateRootDirectory()
            .compactMap { url -> Album? in
                let directoryName = url.lastPathComponent
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let creationDate = attributes?[.creationDate] as? Date
                print("name: \(url), creationDate: \(String(describing: creationDate))")

                return creationDate != nil ? Album(name: directoryName, storageOption: .icloud, creationDate: creationDate!) : nil
            }

        return (localAlbums + iCloudAlbums).sorted { $0.creationDate < $1.creationDate }

    }
    required public init() {
        self.albums = availableAlbums

        // Retrieve the current album ID from user defaults
        if let currentAlbumID = UserDefaultUtils.string(forKey: .currentAlbumID),
            let foundAlbum = availableAlbums.first(where: { $0.id == currentAlbumID }) {
            // Find the album with the matching ID
            self.currentAlbum = foundAlbum
        } else {
            self.currentAlbum = availableAlbums.first
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
        albums.removeAll(where: { $0.id == album.id })
    }

    public func create(album: Album) throws {
        let fileManager = FileManager.default
        let albumURL = album.storageURL

        // Check if the directory already exists
        if fileManager.fileExists(atPath: albumURL.path) {
            // If the directory exists, throw the albumExists error
            throw AlbumError.albumExists
        }

        // If the directory does not exist, create it
        try fileManager.createDirectory(
            at: albumURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Add album to the albums collection
        albums.append(album)
    }


    public func storageModel(for album: Album) -> DataStorageModel? {
        availableAlbums.filter({$0.name == album.name}).first?.storageOption.modelForType.init(album: album)
    }

    public func validateAlbumName(name: String) throws {
        guard name.count > 0 else {
            throw KeyManagerError.keyNameError
        }
    }


}
