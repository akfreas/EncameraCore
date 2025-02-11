//
//  AlbumManaging.swift
//
//
//  Created by Alexander Freas on 19.11.23.
//

import Foundation
import Combine
import UIKit

public protocol AlbumManaging {

    init(keyManager: KeyManager)
    var albums: [Album] { get }

    var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> { get }
    var defaultStorageForAlbum: StorageType { get set }
    var currentAlbum: Album? { get set }
    var currentAlbumMediaCount: Int? { get }
    func delete(album: Album)
    func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>)
    func loadAlbumsFromFilesystem()
    @discardableResult func create(name: String, storageOption: StorageType) throws -> Album
    func storageModel(for album: Album) -> DataStorageModel?
    func moveAlbum(album: Album, toStorage: StorageType) throws -> Album
    func renameAlbum(album: Album, to newName: String) throws -> Album
    func validateAlbumName(name: String) throws
    func albumMediaCount(album: Album) -> Int
    func isAlbumHidden(_ album: Album) -> Bool
    func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album)
}

