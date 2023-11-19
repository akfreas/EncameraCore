//
//  File.swift
//  
//
//  Created by Alexander Freas on 12.11.23.
//

import Foundation
import Combine

public enum AlbumError: ErrorDescribable {

    case albumNameError


    public var displayDescription: String {
        switch self {
        case .albumNameError:
            return L10n.albumNameInvalid
        }
    }

}

public class AlbumManager {

    public var albumPublisher: AnyPublisher<Album?, Never> {
        albumSubject.eraseToAnyPublisher()
    }

    public var defaultStorageForAlbum: StorageType = .local

    private var albumSubject: PassthroughSubject<Album?, Never> = .init()
    public var currentAlbum: Album? {
        didSet {
            albumSubject.send(currentAlbum)
        }
    }
    public var availableAlbums: [Album] {
        let fileManager = FileManager.default

        let localAlbums = LocalStorageModel.enumerateRootDirectory()
            .compactMap { url -> Album? in
                let directoryName = url.lastPathComponent
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let creationDate = attributes?[.creationDate] as? Date
                return creationDate != nil ? Album(name: directoryName, storageOption: .local, creationDate: creationDate!) : nil
            }

        let iCloudAlbums = iCloudStorageModel.enumerateRootDirectory()
            .compactMap { url -> Album? in
                let directoryName = url.lastPathComponent
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                let creationDate = attributes?[.creationDate] as? Date
                return creationDate != nil ? Album(name: directoryName, storageOption: .icloud, creationDate: creationDate!) : nil
            }

        return (localAlbums + iCloudAlbums).sorted { $0.creationDate < $1.creationDate }
    }

    public func delete(album: Album) {
        
    }


    public func storageModel(for album: Album) -> DataStorageModel? {
        availableAlbums.filter({$0.name == album.name}).first?.storageOption.modelForType.init(album: album)
    }

    public func validateAlbumName(name: String) throws {
        guard name.count > 0 else {
            throw KeyManagerError.keyNameError
        }
    }

    required public init() {
    }



}
