//
//  AlbumManaging.swift
//
//
//  Created by Alexander Freas on 19.11.23.
//

import Foundation
import Combine

public protocol AlbumManaging {

    init(keyManager: KeyManager)
    var albums: [Album] { get }
    var albumPublisher: AnyPublisher<[Album], Never> { get }
    var selectedAlbumPublisher: AnyPublisher<Album?, Never> { get }
    var defaultStorageForAlbum: StorageType { get set }
    var currentAlbum: Album? { get set }

    func delete(album: Album)
    @discardableResult func create(name: String, storageOption: StorageType) throws -> Album 
    func storageModel(for album: Album) -> DataStorageModel?
    func moveAlbum(album: Album, toStorage: StorageType) throws -> Album
    func renameAlbum(album: Album, to newName: String) throws -> Album
    func validateAlbumName(name: String) throws
}

