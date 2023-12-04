//
//  AlbumManaging.swift
//
//
//  Created by Alexander Freas on 19.11.23.
//

import Foundation
import Combine

public protocol AlbumManaging {
    var albums: Set<Album> { get }
    var albumPublisher: AnyPublisher<Set<Album>, Never> { get }
    var selectedAlbumPublisher: AnyPublisher<Album?, Never> { get }
    var defaultStorageForAlbum: StorageType { get set }
    var currentAlbum: Album? { get set }
    var availableAlbums: Set<Album> { get }

    func delete(album: Album)
    func create(album: Album) throws
    func storageModel(for album: Album) -> DataStorageModel?
    func moveAlbum(album: Album, toStorage: StorageType) throws
    func validateAlbumName(name: String) throws
}

