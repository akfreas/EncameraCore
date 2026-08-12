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

    init(keyManager: KeyManager, syncedDataStore: SyncedDataStore?)
    var keyManager: KeyManager { get }
    var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> { get }
    var defaultStorageForAlbum: StorageType { get set }
    var currentAlbum: Album? { get set }
    var currentAlbumMediaCount: Int? { get }
    func delete(album: Album)
    func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>)
    func removeAlbumCover(album: Album)
    func resetAlbumCover(album: Album)
    func getAlbumCoverImageId(album: Album) -> String?
    func isAlbumCoverImageDisabled(album: Album) -> Bool
    func fetchAlbumsFromSources(includingHidden: Bool) -> [Album]
    func restoreCurrentAlbumFromUserDefaults()
    @discardableResult func create(name: String, storageOption: StorageType) throws -> Album
    func storageModel(for album: Album) -> DataStorageModel?
    func moveAlbum(album: Album, toStorage: StorageType) throws -> Album
    /// Downloads a CloudKit album's contents into local storage and removes the
    /// remote records — the reverse of the migration engine. See `AlbumManager`.
    func moveCloudKitAlbumToLocal(album: Album) async throws -> Album
    /// Progress-reporting variant of the above: `onProgress` is awaited between
    /// items, so the app can mirror the move into the same blocking overlay the
    /// forward migration shows.
    func moveCloudKitAlbumToLocal(album: Album,
                                  onProgress: (@Sendable (CloudToLocalMoveProgress) async -> Void)?) async throws -> Album
    @discardableResult func finalizeMigrationToCloudKit(album: Album) throws -> Album
    func renameAlbum(album: Album, to newName: String) throws -> Album
    func validateAlbumName(name: String) throws
    func albumMediaCount(album: Album) -> Int
    func isAlbumHidden(_ album: Album) -> Bool
    func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album)
    /// Materializes a CloudKit album discovered by the album reconciler (marker,
    /// hidden state, broadcasts) so remote discovery goes through the manager —
    /// keeping `albumOperationPublisher` observers and `currentAlbum` consistent —
    /// instead of mutating the filesystem behind its back.
    func adoptCloudKitAlbum(name: String, key: PrivateKey, createdAt: Date, isHidden: Bool)
}

public extension AlbumManaging {
    func fetchAlbumsFromSources() -> [Album] {
        fetchAlbumsFromSources(includingHidden: false)
    }

    /// Default for non-CloudKit conformers (previews/test doubles): flip the
    /// storage only. `AlbumManager` overrides this with the real download +
    /// remote cleanup.
    func moveCloudKitAlbumToLocal(album: Album) async throws -> Album {
        var moved = album
        moved.storageOption = .local
        return moved
    }

    /// Default for conformers that don't report progress: run the plain move and
    /// drop the callback. `AlbumManager` overrides this with real reporting.
    func moveCloudKitAlbumToLocal(album: Album,
                                  onProgress: (@Sendable (CloudToLocalMoveProgress) async -> Void)?) async throws -> Album {
        try await moveCloudKitAlbumToLocal(album: album)
    }

    /// Default flip used by non-broadcasting conformers (previews/test doubles):
    /// write the CloudKit discovery marker and drop the drained source directory.
    /// `AlbumManager` overrides this to also broadcast the change.
    @discardableResult
    func finalizeMigrationToCloudKit(album: Album) throws -> Album {
        let cloudKitAlbum = Album.cloudKitTwin(of: album)
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(cloudKitAlbum.encryptedPathComponent)
        // The marker is the only discovery mechanism for CloudKit albums — surface
        // a write failure instead of silently finishing with an unreachable album.
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw AlbumError.cloudKitMarkerWriteFailed
        }
        if album.storageOption != .cloudKit {
            let sourceModel = album.storageOption.modelForType.init(album: album)
            Album.removeDrainedSourceDirectory(at: sourceModel.baseURL)
        }
        return cloudKitAlbum
    }

    /// Whether the album's CloudKit discovery marker exists — i.e. whether a
    /// migration actually finalized. Reads the same artefact
    /// `finalizeMigrationToCloudKit` writes above and `fetchAlbumsFromSources`
    /// derives its `.cloudKit` albums from, so it is the one true answer to "did
    /// this album really move", available to callers outside this module that
    /// must not report a migration they did not achieve.
    func hasFinalizedToCloudKit(album: Album) -> Bool {
        let marker = CloudKitStorageModel.albumsURL
            .appendingPathComponent(Album.cloudKitTwin(of: album).encryptedPathComponent)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// Default no-op so lightweight test/demo conformers need not implement it.
    func adoptCloudKitAlbum(name: String, key: PrivateKey, createdAt: Date, isHidden: Bool) {}
}
