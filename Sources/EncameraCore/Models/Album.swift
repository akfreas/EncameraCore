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

    /// The same album (same name + key) re-pointed at CloudKit storage — the single
    /// owner of "make the `.cloudKit` twin of this album", used by the migration engine
    /// and the album flip so the semantics live in one place.
    public static func cloudKitTwin(of album: Album) -> Album {
        var twin = album
        twin.storageOption = .cloudKit
        return twin
    }

    /// Removes a migrated album's drained source directory, but ONLY when it holds no
    /// regular files — so a ciphertext the migration plan never enumerated (an orphaned
    /// or partially-written file) is preserved rather than silently destroyed. A
    /// not-fully-drained directory is left in place (the album simply remains
    /// discoverable in its source storage). Returns whether the directory is now gone.
    @discardableResult
    public static func removeDrainedSourceDirectory(at baseURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseURL.path) else { return true }
        if let enumerator = fileManager.enumerator(at: baseURL,
                                                   includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isRegularFile {
                    // Say WHAT blocked it. Silently returning false leaves the album
                    // still discoverable in its source storage with no explanation —
                    // which on the rig looked like a migration that had lost files,
                    // and took a device run per guess to narrow down.
                    printDebug("removeDrainedSourceDirectory KEPT \(baseURL.lastPathComponent) — leftover file \(url.lastPathComponent)")
                    return false   // leftover data — never delete
                }
            }
        }
        try? fileManager.removeItem(at: baseURL)
        return true
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

    /// The album's real name, or nil when this key did not encrypt it.
    ///
    /// The lossy sibling below reports failure by handing back its own input, which
    /// cannot be used as proof of anything: "the key was wrong" and "the name decrypted
    /// to itself" are the same value. Key resolution needs to tell those apart, and the
    /// secretstream pull is authenticated, so nil here carries the same weight as a
    /// failed first-block probe on a file.
    ///
    /// A name without the `Album_` prefix is not ciphertext at all and yields nil — no
    /// key encrypted it, so no key can be proven by it.
    public static func decryptedAlbumName(_ encryptedName: String, key: PrivateKey) -> String? {
        guard encryptedName.starts(with: "Album_") else {
            return nil
        }

        let sodium = Sodium()

        let base64String = encryptedName
            .replacingOccurrences(of: "Album_", with: "")
            .replacingOccurrences(of: "_", with: "/")

        guard let encryptedData = Data(base64Encoded: base64String) else {
            debugPrint("Could not decode base64 string for album with name: \(encryptedName)")
            return nil
        }

        let headerBytesCount = SecretStream.XChaCha20Poly1305.HeaderBytes

        guard encryptedData.count > headerBytesCount else {
            debugPrint("Not enough bytes to extract header: \(encryptedData.count) bytes found, but need at least \(headerBytesCount + 1)")
            return nil
        }

        let header = Array(encryptedData.prefix(headerBytesCount))

        let messageBytes = Array(encryptedData.dropFirst(headerBytesCount))

        guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: key.keyBytes, header: header) else {
            debugPrint("Could not create stream with key for album with name: \(encryptedName)")
            return nil
        }

        guard let (decryptedMessage, _) = streamDec.pull(cipherText: messageBytes) else {
            debugPrint("Could not decrypt message for album with name: \(encryptedName)")
            return nil
        }

        return String(bytes: decryptedMessage, encoding: .utf8)
    }

    /// The album's name for display, falling back to the ciphertext when this key
    /// cannot open it. Kept because callers rely on getting *something* renderable
    /// back; anything deciding which key to use wants `decryptedAlbumName` instead.
    public static func decryptAlbumName(_ encryptedName: String, key: PrivateKey) -> String {
        decryptedAlbumName(encryptedName, key: key) ?? encryptedName
    }
}

/// So `removeDrainedSourceDirectory` can report what stopped it from deleting a
/// migrated album's source directory — on a device that message is the difference
/// between a diagnosis and a guess.
extension Album: DebugPrintable {}

/// An album whose encryption key is not on this device. Carries enough metadata
/// to render a locked placeholder in the grid without exposing any decrypted
/// content or requiring a `PrivateKey`.
public struct LockedAlbumPlaceholder: Identifiable, Hashable {
    public let encryptedDirectoryName: String
    public let storageOption: StorageType
    public let creationDate: Date

    public var id: String {
        "\(encryptedDirectoryName)_\(storageOption.rawValue)"
    }

    public init(encryptedDirectoryName: String, storageOption: StorageType, creationDate: Date) {
        self.encryptedDirectoryName = encryptedDirectoryName
        self.storageOption = storageOption
        self.creationDate = creationDate
    }
}
