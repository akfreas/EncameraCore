//
//  KeyResolutionTests.swift
//  EncameraCoreTests
//
//  `KeyDiscovery` as an instance: resolving which key opens a piece of ciphertext that
//  is not a file — an album's encrypted directory name, or an encrypted blob.
//
//  The file path already worked this way (try candidates, prove each by an
//  authenticated decrypt). These tests pin the same discipline for the shapes that
//  have no prologue to probe, and pin the two answers that are NOT "resolved": a
//  ciphertext no key opens is a locked album, and an input carrying no authentication
//  at all cannot be used as proof of anything.
//

import XCTest
@testable import EncameraCore

final class KeyResolutionTests: XCTestCase {

    private let keyA = PrivateKey(name: AppConstants.defaultKeyName,
                                  keyBytes: Array(repeating: 0xA1, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 1_000))
    private let keyB = PrivateKey(name: AppConstants.defaultKeyName,
                                  keyBytes: Array(repeating: 0xB2, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 2_000))
    private let keyC = PrivateKey(name: AppConstants.defaultKeyName,
                                  keyBytes: Array(repeating: 0xC3, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 3_000))

    private func discovery(keys: [PrivateKey], current: PrivateKey?) -> KeyDiscovery {
        let keyManager = DemoKeyManager(keys: keys)
        keyManager.currentKey = current
        return KeyDiscovery(keyManager: keyManager)
    }

    /// The encrypted directory name an album of this name under this key would have.
    private func encryptedName(_ name: String, key: PrivateKey) -> String {
        Album(name: name, storageOption: .local, creationDate: Date(), key: key).encryptedPathComponent
    }

    // MARK: - Album names

    func testResolvesTheKeyThatEncryptedTheAlbumName() {
        let ciphertext = encryptedName("Holiday", key: keyB)
        let resolver = discovery(keys: [keyA, keyB, keyC], current: keyA)

        guard case .resolved(let key) = resolver.key(forEncryptedAlbumName: ciphertext, hint: nil) else {
            return XCTFail("A key in the library encrypted this name; resolution must find it")
        }
        XCTAssertEqual(key.keychainLabel, keyB.keychainLabel)
    }

    /// The current key must not win by being current — it is a candidate like any
    /// other, and only the decrypt decides.
    func testCurrentKeyDoesNotWinWhenItCannotDecrypt() {
        let ciphertext = encryptedName("Holiday", key: keyC)
        let resolver = discovery(keys: [keyA, keyB, keyC], current: keyA)

        guard case .resolved(let key) = resolver.key(forEncryptedAlbumName: ciphertext, hint: nil) else {
            return XCTFail("Key C is in the library and encrypted this name")
        }
        XCTAssertEqual(key.keychainLabel, keyC.keychainLabel,
                       "Resolution returned the current key over the one that actually decrypts")
    }

    /// A name no held key opens is a locked album — distinct from "not provable", and
    /// the caller must not fall back to the current key for it.
    func testNameEncryptedWithAnAbsentKeyIsNoKnownKey() {
        let ciphertext = encryptedName("Holiday", key: keyC)
        let resolver = discovery(keys: [keyA, keyB], current: keyA)

        guard case .noKnownKey = resolver.key(forEncryptedAlbumName: ciphertext, hint: nil) else {
            return XCTFail("No key here can decrypt this name, so the album is locked")
        }
    }

    /// A legacy plaintext directory name is returned verbatim by every key, so every
    /// key "succeeds" and the proof is vacuous. Reporting `.resolved` here would pin a
    /// meaningless winner; the caller needs to know it learned nothing.
    func testPlaintextNameIsNotProvable() {
        let resolver = discovery(keys: [keyA, keyB], current: keyA)

        guard case .notProvable = resolver.key(forEncryptedAlbumName: "MyOldAlbum", hint: nil) else {
            return XCTFail("A name that is not `Album_`-prefixed carries no authentication to test")
        }
    }

    // MARK: - Hints

    /// A hint is an ordering optimization. It may not decide the answer, because the
    /// thing that supplies it (a CloudKit record field) is not covered by the AEAD.
    func testWrongHintDoesNotWin() {
        let ciphertext = encryptedName("Holiday", key: keyB)
        let resolver = discovery(keys: [keyA, keyB, keyC], current: keyA)

        guard case .resolved(let key) = resolver.key(forEncryptedAlbumName: ciphertext,
                                                     hint: keyC.keychainLabel) else {
            return XCTFail("A wrong hint must fall through to the rest of the library, not fail")
        }
        XCTAssertEqual(key.keychainLabel, keyB.keychainLabel,
                       "The hint named C but only B decrypts; the decrypt has to decide")
    }

    func testCorrectHintResolves() {
        let ciphertext = encryptedName("Holiday", key: keyC)
        let resolver = discovery(keys: [keyA, keyB, keyC], current: keyA)

        guard case .resolved(let key) = resolver.key(forEncryptedAlbumName: ciphertext,
                                                     hint: keyC.keychainLabel) else {
            return XCTFail("The hinted key does decrypt this name")
        }
        XCTAssertEqual(key.keychainLabel, keyC.keychainLabel)
    }

    // MARK: - Non-lossy album-name decryption

    /// `Album.decryptAlbumName` reports failure by returning its input, which is
    /// unusable as proof — "it came back unchanged" and "it decrypted to itself" are
    /// the same value. The sibling returns nil so a caller can tell.
    func testDecryptedAlbumNameIsNilForTheWrongKey() {
        let ciphertext = encryptedName("Holiday", key: keyA)

        XCTAssertEqual(Album.decryptedAlbumName(ciphertext, key: keyA), "Holiday")
        XCTAssertNil(Album.decryptedAlbumName(ciphertext, key: keyB),
                     "Key B did not encrypt this name and must not appear to have decrypted it")
    }

    /// The lossy original has to keep behaving exactly as it did, since callers rely
    /// on getting the ciphertext back rather than a crash or an empty string.
    func testLossyDecryptAlbumNameStillReturnsItsInputOnFailure() {
        let ciphertext = encryptedName("Holiday", key: keyA)

        XCTAssertEqual(Album.decryptAlbumName(ciphertext, key: keyA), "Holiday")
        XCTAssertEqual(Album.decryptAlbumName(ciphertext, key: keyB), ciphertext)
    }

    // MARK: - Blobs

    func testResolvesTheKeyThatEncryptedABlob() throws {
        let plaintext = Data("index contents".utf8)
        let blob = try MediaIndexStore.encrypt(plaintext, keyBytes: keyB.keyBytes)
        let resolver = discovery(keys: [keyA, keyB, keyC], current: keyA)

        guard case .resolved(let key) = resolver.key(forCiphertextBlob: blob, hint: nil) else {
            return XCTFail("Key B encrypted this blob and is in the library")
        }
        XCTAssertEqual(key.keychainLabel, keyB.keychainLabel)
    }

    func testBlobEncryptedWithAnAbsentKeyIsNoKnownKey() throws {
        let blob = try MediaIndexStore.encrypt(Data("index contents".utf8), keyBytes: keyC.keyBytes)
        let resolver = discovery(keys: [keyA, keyB], current: keyA)

        guard case .noKnownKey = resolver.key(forCiphertextBlob: blob, hint: nil) else {
            return XCTFail("No key here opens this blob")
        }
    }

    /// Bytes that are not this format at all cannot prove anything about a key.
    func testGarbageBlobIsNotProvable() {
        let resolver = discovery(keys: [keyA, keyB], current: keyA)

        guard case .notProvable = resolver.key(forCiphertextBlob: Data([0x00, 0x01, 0x02]), hint: nil) else {
            return XCTFail("A too-short, unparseable blob carries no authentication to test")
        }
    }

    // MARK: - Empty library

    func testEmptyLibraryIsNoKnownKey() {
        let ciphertext = encryptedName("Holiday", key: keyA)
        let resolver = discovery(keys: [], current: nil)

        guard case .noKnownKey = resolver.key(forEncryptedAlbumName: ciphertext, hint: nil) else {
            return XCTFail("With no keys at all, nothing can be resolved")
        }
    }
}
