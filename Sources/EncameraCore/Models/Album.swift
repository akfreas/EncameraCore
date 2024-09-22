//
//  Album.swift
//
//
//  Created by Alexander Freas on 26.10.23.
//

import Foundation
import Combine
import Sodium

public struct Album: Codable, Identifiable, Hashable {

    public init(name: String, storageOption: StorageType, creationDate: Date, key: PrivateKey) {
        self.name = name
        self.storageOption = storageOption
        self.creationDate = creationDate
        self.key = key
        self.encryptedName = encryptedPathComponent
    }

    public init(encryptedName: String, storageOption: StorageType, creationDate: Date, key: PrivateKey) {
        self.storageOption = storageOption
        self.creationDate = creationDate
        self.key = key
        self.name = Self.decryptAlbumName(encryptedName, key: key)
        self.encryptedName = encryptedName
    }

    public var key: PrivateKey
    public var name: String {
        didSet {
            encryptedName = nil
            encryptedName = encryptedPathComponent
        }
    }
    public var storageOption: StorageType
    public var creationDate: Date
    private var encryptedName: String?

    public var id: String {
        return "\(name)_\(storageOption.rawValue)"
    }

    public var storageURL: URL {
        storageOption.modelForType.init(album: self).baseURL
    }

    // MARK: - Encrypt Album Name
    public var encryptedPathComponent: String {
        if let encryptedName = encryptedName {
            return encryptedName
        }
        guard let streamEnc = Sodium().secretStream.xchacha20poly1305.initPush(secretKey: key.keyBytes) else {
            debugPrint("Could not create stream with key")
            return name
        }

        let nameBytes = Array(name.utf8)

        if let encryptedMessage = streamEnc.push(message: nameBytes, tag: .FINAL) {
            var combinedData = Data(streamEnc.header()) // Add the header (24 bytes)
            combinedData.append(contentsOf: encryptedMessage) // Append the encrypted message

            let finalComponent = "Album_" + combinedData.base64EncodedString().replacingOccurrences(of: "/", with: "_")
            return finalComponent
        } else {
            return name
        }
    }

    // MARK: - Decrypt Album Name
    public static func decryptAlbumName(_ encryptedName: String, key: PrivateKey) -> String {
        if !encryptedName.starts(with: "Album_") {
            return encryptedName
        }

        let sodium = Sodium()

        let base64String = encryptedName
            .replacingOccurrences(of: "Album_", with: "")
            .replacingOccurrences(of: "_", with: "/")

        guard let encryptedData = Data(base64Encoded: base64String) else {
            debugPrint("Could not decode base64 string for album with name: \(encryptedName)")
            return encryptedName
        }

        let headerBytesCount = SecretStream.XChaCha20Poly1305.HeaderBytes

        guard encryptedData.count > headerBytesCount else {
            debugPrint("Not enough bytes to extract header: \(encryptedData.count) bytes found, but need at least \(headerBytesCount + 1)")
            return encryptedName
        }

        let header = Array(encryptedData.prefix(headerBytesCount))

        let messageBytes = Array(encryptedData.dropFirst(headerBytesCount))

        guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: key.keyBytes, header: header) else {
            debugPrint("Could not create stream with key for album with name: \(encryptedName)")
            return encryptedName
        }

        guard let (decryptedMessage, _) = streamDec.pull(cipherText: messageBytes) else {
            debugPrint("Could not decrypt message for album with name: \(encryptedName)")
            return encryptedName
        }

        return String(bytes: decryptedMessage, encoding: .utf8) ?? encryptedName
    }
}
