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
}

public protocol FileEnumerator {
    func configure(with key: PrivateKey?, storageSettingsManager: DataStorageSetting) async
    func enumerateMedia<T: MediaDescribing>() async -> [T] where T.MediaSource == URL
}

public protocol FileReader {
    func configure(with key: PrivateKey?, storageSettingsManager: DataStorageSetting) async
    func loadLeadingThumbnail() async throws -> UIImage?
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL
    func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL>
    func loadMediaInMemory<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<Data>
}

public protocol FileWriter {
        
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia
    @discardableResult func createPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel
    func copy(media: EncryptedMedia) async throws
    func delete(media: EncryptedMedia) async throws
    func deleteMedia(for key: PrivateKey) async throws
    func moveAllMedia(for keyName: KeyName, toRenamedKey newKeyName: KeyName) async throws
    func deleteAllMedia() async throws
}

public protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init()
}

extension FileAccess {
    var operationBus: FileOperationBus {
        FileOperationBus.shared
    }
}
