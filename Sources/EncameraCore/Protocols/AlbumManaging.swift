//
//  AlbumManaging.swift
//
//
//  Created by Alexander Freas on 19.11.23.
//

import Foundation
import Combine

public protocol AlbumManaging {
    var albums: [Album] { get }
    var albumPublisher: AnyPublisher<[Album], Never> { get }
    var selectedAlbumPublisher: AnyPublisher<Album?, Never> { get }
    var defaultStorageForAlbum: StorageType { get set }
    var currentAlbum: Album? { get set }
    var availableAlbums: [Album] { get }

    func delete(album: Album)
    func create(album: Album) throws
    func storageModel(for album: Album) -> DataStorageModel?
    func validateAlbumName(name: String) throws
}

