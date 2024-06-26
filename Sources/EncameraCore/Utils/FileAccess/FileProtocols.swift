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
    func enumerateMedia<T: MediaDescribing>() async -> [T] where T.MediaSource == URL
}

public protocol FileReader: FileEnumerator {
    
    func configure(for album: Album, albumManager: AlbumManaging) async
    func loadLeadingThumbnail() async throws -> UIImage?
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL
    func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia<URL>
    func loadMediaInMemory<T: MediaDescribing>(media: T, progress: @escaping (FileLoadingStatus) -> Void) async throws -> CleartextMedia<Data>
}

public protocol FileWriter: FileEnumerator {
        
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>, progress: @escaping (Double) -> Void) async throws -> EncryptedMedia?
    @discardableResult func createPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel
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
