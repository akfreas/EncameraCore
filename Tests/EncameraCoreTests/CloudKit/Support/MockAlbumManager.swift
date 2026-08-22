//
//  MockAlbumManager.swift
//  EncameraCoreTests
//
//  Minimal AlbumManaging for FileAccess tests: just enough to satisfy
//  the preview pipeline (key access + storage model).
//

import Foundation
import Combine
import UIKit
@testable import EncameraCore

final class MockAlbumManager: AlbumManaging {

    var keyManager: KeyManager
    var defaultStorageForAlbum: StorageType = .local
    var currentAlbum: Album?
    var currentAlbumMediaCount: Int? { nil }
    var albumsOnDisk: [Album] = []

    // Instrumentation for reconciler tests
    private(set) var deletedAlbums: [Album] = []
    private(set) var adoptedAlbums: [(name: String, isHidden: Bool)] = []
    private(set) var setHiddenCalls: [(name: String, isHidden: Bool)] = []
    var hiddenAlbumNames: Set<String> = []

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    required init(keyManager: KeyManager, syncedDataStore: SyncedDataStore?) {
        self.keyManager = keyManager
    }

    var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> {
        Empty().eraseToAnyPublisher()
    }

    func storageModel(for album: Album) -> DataStorageModel? {
        album.storageOption.modelForType.init(album: album)
    }

    func delete(album: Album) {
        deletedAlbums.append(album)
        albumsOnDisk.removeAll { $0.name == album.name }
    }
    func adoptCloudKitAlbum(name: String, key: PrivateKey, createdAt: Date, isHidden: Bool) {
        adoptedAlbums.append((name: name, isHidden: isHidden))
        albumsOnDisk.append(Album(name: name, storageOption: .cloudKit, creationDate: createdAt, key: key))
    }
    func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {}
    func removeAlbumCover(album: Album) {}
    func resetAlbumCover(album: Album) {}
    func getAlbumCoverImageId(album: Album) -> String? { nil }
    func isAlbumCoverImageDisabled(album: Album) -> Bool { false }
    /// Albums returned only when the caller asks for hidden ones, so a test can prove
    /// a reader passes `includingHidden: true` rather than trusting it does.
    var hiddenAlbumsOnDisk: [Album] = []
    private(set) var fetchIncludingHiddenCalls: [Bool] = []

    func fetchAlbumsFromSources(includingHidden: Bool) -> [Album] {
        fetchIncludingHiddenCalls.append(includingHidden)
        return includingHidden ? albumsOnDisk + hiddenAlbumsOnDisk : albumsOnDisk
    }
    func restoreCurrentAlbumFromUserDefaults() {}
    @discardableResult func create(name: String, storageOption: StorageType) throws -> Album {
        Album(name: name, storageOption: storageOption, creationDate: Date(), key: keyManager.currentKey!)
    }
    func moveAlbum(album: Album, toStorage: StorageType) throws -> Album { album }

    private(set) var moveToLocalCallCount = 0
    func moveCloudKitAlbumToLocal(album: Album) async throws -> Album {
        moveToLocalCallCount += 1
        var moved = album
        moved.storageOption = .local
        return moved
    }

    private(set) var finalizeCallCount = 0
    private(set) var finalizedAlbums: [Album] = []
    /// Set to make `finalizeMigrationToCloudKit` throw (e.g. the marker write
    /// failing), so tests can exercise the kept-checkpoint retry path.
    var finalizeError: Error?
    func finalizeMigrationToCloudKit(album: Album) throws -> Album {
        finalizeCallCount += 1
        if let finalizeError { throw finalizeError }
        var cloudKitAlbum = album
        cloudKitAlbum.storageOption = .cloudKit
        finalizedAlbums.append(cloudKitAlbum)
        // Mirror the real AlbumManager: finalize writes the CloudKit discovery
        // marker (the engine's already-finalized detection keys on its presence)
        // and drops the drained source dir.
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(cloudKitAlbum.encryptedPathComponent)
        try? FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        let sourceModel = album.storageOption.modelForType.init(album: album)
        Album.removeDrainedSourceDirectory(at: sourceModel.baseURL)
        return cloudKitAlbum
    }
    func renameAlbum(album: Album, to newName: String) throws -> Album { album }
    func validateAlbumName(name: String) throws {}
    func albumMediaCount(album: Album) -> Int { 0 }
    func isAlbumHidden(_ album: Album) -> Bool { hiddenAlbumNames.contains(album.name) }
    func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album) {
        setHiddenCalls.append((name: album.name, isHidden: isAlbumHidden))
        if isAlbumHidden { hiddenAlbumNames.insert(album.name) } else { hiddenAlbumNames.remove(album.name) }
    }
}
