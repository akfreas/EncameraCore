//
//  FileProtocols.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine
import UIKit

public enum FileAccessError: Error {
    case missingDirectoryModel
    case missingPrivateKey
    case unhandledMediaType
    case couldNotLoadMedia
}

public enum FileLoadingStatus {
    case notLoaded
    case downloading(progress: Double)
    case decrypting(progress: Double)
    case loaded
}

public protocol FileEnumerator {

    func configure(for album: Album, albumManager: AlbumManaging) async
    func enumerateMedia<T: MediaDescribing>() async -> [T]
}

public protocol FileReader: FileEnumerator {
    
    func configure(for album: Album, albumManager: AlbumManaging) async
    func loadLeadingThumbnail() async throws -> UIImage?
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel
    func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia
    func loadMediaInMemory<T: MediaDescribing>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia
}

public protocol FileWriter: FileEnumerator {
        
    @discardableResult func save(media: CleartextMedia, progress: @escaping (Double) -> Void) async throws -> EncryptedMedia?
    @discardableResult func createPreview(for media: CleartextMedia) async throws -> PreviewModel
    func copy(media: EncryptedMedia) async throws
    func move(media: EncryptedMedia) async throws
    func delete(media: EncryptedMedia) async throws
    func deleteMediaForKey() async throws
    func moveAllMedia(for keyName: KeyName, toRenamedKey newKeyName: KeyName) async throws
    func deleteAllMedia() async throws
    static func deleteThumbnailDirectory() throws
}

public protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init()
    init(for album: Album, albumManager: AlbumManaging) async
}

extension FileAccess {
    var operationBus: FileOperationBus {
        FileOperationBus.shared
    }
}
