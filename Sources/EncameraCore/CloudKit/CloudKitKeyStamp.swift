//
//  CloudKitKeyStamp.swift
//  EncameraCore
//
//  The single place a CloudKit-bound ciphertext's key is established.
//

import Foundation

/// Establishes which key encrypted a ciphertext file, for every writer that puts a
/// `keyFingerprint` on a CloudKit record.
///
/// Readers take that field as the answer and decrypt with the key it names, without
/// re-deriving anything — which is only safe because the field can never be a guess.
/// This type is what makes that true: a fingerprint reaches a record only after the
/// key it names has authenticated the very bytes being uploaded, and a file whose key
/// cannot be established fails its item instead of uploading under an assumption.
///
/// The file is always local at this point — a capture writes it to the album's cache
/// directory, and a migration only reaches an item whose source is materialized — so
/// the proof is a bounded local read (the prologue plus one ~20KB block) and one AEAD
/// operation per candidate key.
public enum CloudKitKeyStamp: DebugPrintable {

    /// A key that authenticated a specific file, and the identity that goes on the record.
    public struct ProvenKey: Equatable {
        public let key: PrivateKey

        /// Lowercase hex of the full 16-byte fingerprint — what `EncMedia.keyFingerprint`
        /// and `EncAlbum.keyFingerprint` carry. The in-file stamp is the first 4 bytes of
        /// this same value, which is why a blob and its record agree by construction.
        public var fingerprint: String { key.keychainLabel }
    }

    /// Why a file may not be uploaded.
    ///
    /// The two cases need opposite handling and must never be collapsed. A missing key
    /// is recoverable — the user can add the key phrase and migrate again. Unreadable
    /// bytes are not, and reporting them as a missing key sends someone hunting for a
    /// key phrase that will not help.
    public enum Failure: Error, Equatable, ErrorDescribable {
        /// Well-formed ciphertext that no key in the library authenticates. The stamp is
        /// carried when the file has one, so the missing key can be named.
        case missingKey(fileName: String, requiredStampPrefix: UInt32?)

        /// The bytes do not parse as encrypted media, so no key was ever really tested.
        case unreadable(fileName: String)

        public var displayDescription: String {
            switch self {
            case .missingKey(let fileName, let stamp):
                guard let stamp else {
                    return L10n.MissingKey.subtitleUnknown + " (\(fileName))"
                }
                return L10n.MissingKey.subtitleWithFingerprint(KeyFingerprint.displayLabel(stampPrefix: stamp))
                    + " (\(fileName))"
            case .unreadable(let fileName):
                return "\(fileName) could not be read as encrypted media."
            }
        }
    }

    /// The fingerprint an `EncAlbum` record must carry: the key that decrypts the
    /// album's own encrypted name.
    ///
    /// A receiving device recognises an album by decrypting `encName`, so the record has
    /// to name the key that actually opens it. `album.key` is what the local album layer
    /// resolved, which is the same key in every ordinary case — but it is the writer's
    /// assumption, and this is the write boundary, so it is proven here for the same
    /// reason a media blob's key is.
    ///
    /// An album whose name predates name encryption has nothing to prove a key with, and
    /// keeps the album's own key. Nil means a held key was required and none opened the
    /// name: publish nothing, because a record naming a key that cannot decrypt its own
    /// `encName` is unmatchable on every device that receives it.
    public static func provenAlbumFingerprint(for album: Album,
                                              keyManager: KeyManager,
                                              storedKeysSnapshot: [PrivateKey]? = nil) -> String? {
        let resolution = KeyDiscovery(keyManager: keyManager)
            .key(forEncryptedAlbumName: album.encryptedPathComponent,
                 hint: album.key.keychainLabel,
                 storedKeysSnapshot: storedKeysSnapshot)
        switch resolution {
        case .resolved(let key):
            return key.keychainLabel
        case .notProvable:
            return album.key.keychainLabel
        case .noKnownKey:
            printDebug("provenAlbumFingerprint: no held key decrypts this album's name; not publishing a record for it")
            return nil
        }
    }

    /// The key that encrypted `url`, proven by authenticating its first ciphertext block.
    ///
    /// `storedKeysSnapshot` lets a caller migrating a whole album read the key library
    /// once instead of once per item; the keychain query is the expensive part of this.
    public static func proveKey(forCiphertextAt url: URL,
                                keyManager: KeyManager,
                                storedKeysSnapshot: [PrivateKey]? = nil) async throws -> ProvenKey {
        switch await KeyDiscovery.discoverKeyOutcome(for: url,
                                                     keyManager: keyManager,
                                                     storedKeysSnapshot: storedKeysSnapshot) {
        case .resolved(let discovered):
            return ProvenKey(key: discovered.key)

        case .noKnownKey(let requiredStampPrefix):
            printDebug("proveKey MISSING KEY file=\(url.lastPathComponent) stamped=\(requiredStampPrefix != nil)")
            throw Failure.missingKey(fileName: url.lastPathComponent,
                                     requiredStampPrefix: requiredStampPrefix)

        case .unreadable:
            printDebug("proveKey UNREADABLE file=\(url.lastPathComponent)")
            throw Failure.unreadable(fileName: url.lastPathComponent)
        }
    }

    /// `proveKey`, and additionally leaves the file carrying its own key's stamp.
    ///
    /// This is what closes the loop through CloudKit. A blob is uploaded as raw bytes
    /// and comes back as raw bytes — `exportCiphertext` is a byte copy — so without a
    /// stamp written before the upload, a CloudKit → local move produces files with
    /// nothing on them naming their key, which is the blind spot the stamp exists to
    /// close.
    ///
    /// A file inside the ubiquity container is never written in place — a one-byte
    /// change there marks the whole file dirty and re-uploads it to iCloud Drive, which
    /// on a migration means re-uploading gigabytes that are about to be deleted. Use
    /// `stampedCopyForUpload` for those: it stamps a temporary copy so the bytes that
    /// reach CloudKit still carry the stamp.
    public static func stampAndProveKey(forCiphertextAt url: URL,
                                        keyManager: KeyManager,
                                        storedKeysSnapshot: [PrivateKey]? = nil) async throws -> ProvenKey {
        let proven = try await proveKey(forCiphertextAt: url,
                                        keyManager: keyManager,
                                        storedKeysSnapshot: storedKeysSnapshot)
        if mayRewrite(url), KeyStampSlot.readStamp(url: url) != proven.key.stampPrefix {
            KeyStampSlot.writeStamp(proven.key.stampPrefix, url: url)
        }
        return proven
    }

    /// The URL to upload from, stamped, plus a cleanup handle.
    ///
    /// For an ordinary local file this is the file itself, already stamped in place, and
    /// `cleanUp` does nothing. For a file in the ubiquity container it is a stamped copy
    /// in the temporary directory, and `cleanUp` removes it once the upload is done — the
    /// user's iCloud Drive file is never modified, and the bytes CloudKit receives still
    /// name their key.
    public struct StampedSource {
        public let key: PrivateKey
        public let uploadURL: URL
        private let temporaryCopy: URL?

        public var fingerprint: String { key.keychainLabel }

        init(key: PrivateKey, uploadURL: URL, temporaryCopy: URL?) {
            self.key = key
            self.uploadURL = uploadURL
            self.temporaryCopy = temporaryCopy
        }

        public func cleanUp() {
            guard let temporaryCopy else { return }
            try? FileManager.default.removeItem(at: temporaryCopy)
        }
    }

    /// Proves the key and guarantees the uploaded bytes carry its stamp, whether or not
    /// the source file may be written in place.
    public static func stampedSourceForUpload(at url: URL,
                                              keyManager: KeyManager,
                                              storedKeysSnapshot: [PrivateKey]? = nil) async throws -> StampedSource {
        let proven = try await stampAndProveKey(forCiphertextAt: url,
                                                keyManager: keyManager,
                                                storedKeysSnapshot: storedKeysSnapshot)
        guard !mayRewrite(url) else {
            return StampedSource(key: proven.key, uploadURL: url, temporaryCopy: nil)
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckstamp-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            KeyStampSlot.writeStamp(proven.key.stampPrefix, url: copy)
            guard KeyStampSlot.readStamp(url: copy) == proven.key.stampPrefix else {
                try? FileManager.default.removeItem(at: copy)
                printDebug("stampedSourceForUpload copy could not be stamped file=\(url.lastPathComponent); uploading the original unstamped")
                return StampedSource(key: proven.key, uploadURL: url, temporaryCopy: nil)
            }
            return StampedSource(key: proven.key, uploadURL: copy, temporaryCopy: copy)
        } catch {
            // An unstamped upload is worse than a stamped one but far better than a
            // failed migration: the record still names the key, which is what readers use.
            printDebug("stampedSourceForUpload copy FAILED file=\(url.lastPathComponent) raw=\(error); uploading the original unstamped")
            return StampedSource(key: proven.key, uploadURL: url, temporaryCopy: nil)
        }
    }

    /// Writes `fingerprint`'s stamp onto a file that just came down from CloudKit.
    ///
    /// The record's fingerprint is the full 16 bytes and the stamp is its first 4, so
    /// the prefix is recoverable from the hex alone — no key material needed, which
    /// matters because an export may run for media whose key this device does not hold.
    public static func stampExportedFile(at url: URL, fingerprint: String) {
        guard let prefix = stampPrefix(fromFingerprintHex: fingerprint) else {
            printDebug("stampExportedFile SKIPPED file=\(url.lastPathComponent) reason=unparseableFingerprint")
            return
        }
        guard KeyStampSlot.readStamp(url: url) != prefix else { return }
        KeyStampSlot.writeStamp(prefix, url: url)
    }

    /// The first 4 fingerprint bytes as the little-endian `UInt32` the stamp slot holds.
    /// Nil for a fingerprint that is not the expected hex, and for the all-zero prefix,
    /// which the slot reserves to mean "unstamped".
    static func stampPrefix(fromFingerprintHex fingerprint: String) -> UInt32? {
        let hex = Array(fingerprint.prefix(8))
        guard hex.count == 8 else { return nil }
        var bytes: [UInt8] = []
        for pair in stride(from: 0, to: 8, by: 2) {
            guard let byte = UInt8(String(hex[pair...pair + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        let prefix = bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        return prefix == 0 ? nil : prefix
    }

    /// The ubiquity container, resolved once. Nil when the device has none.
    private static let ubiquityDocumentsURL: URL? = FileManager.default
        .url(forUbiquityContainerIdentifier: nil)?
        .appendingPathComponent("Documents")

    private static func mayRewrite(_ url: URL) -> Bool {
        guard let ubiquityDocuments = ubiquityDocumentsURL else { return true }
        return !url.standardizedFileURL.path.hasPrefix(ubiquityDocuments.standardizedFileURL.path)
    }
}
