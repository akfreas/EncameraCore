//
//  AlbumKeyResolutionTests.swift
//  EncameraCoreTests
//
//  Which key an album is opened with.
//
//  An album's directory name is its name encrypted with the album's own key, so the
//  key is recoverable from the ciphertext by trying candidates and keeping the one
//  that authenticates. A name cannot identify it: every key Encamera mints is named
//  `encamera_default_key`.
//
//  These only bite once the library holds two keys — the ordinary state of any account
//  whose second device was set up independently. `Album.key` is not cosmetic: the
//  album's name, its identity, its media index and its CloudKit hash all derive from
//  it, so an album given the wrong key becomes a different album.
//

import XCTest
@testable import EncameraCore

final class AlbumKeyResolutionTests: XCTestCase {

    private let keyA = PrivateKey(name: AppConstants.defaultKeyName,
                                  keyBytes: Array(repeating: 0xA1, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 1_000))
    private let keyB = PrivateKey(name: AppConstants.defaultKeyName,
                                  keyBytes: Array(repeating: 0xB2, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 2_000))
    private let keyC = PrivateKey(name: AppConstants.defaultKeyName,
                                  keyBytes: Array(repeating: 0xC3, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 3_000))

    /// Album directories this test created, removed in teardown. The storage models
    /// read the process's real Documents directory and offer no injection point, so
    /// the fixtures go there under names no other test would produce.
    private var createdAlbumDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in createdAlbumDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        createdAlbumDirectories = []
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Writes the on-disk directory a local album of this name under this key would
    /// have, and returns the album the app should reconstruct from it.
    @discardableResult
    private func seedLocalAlbum(named name: String, key: PrivateKey) throws -> Album {
        let album = Album(name: name, storageOption: .local, creationDate: Date(), key: key)
        let url = LocalStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent,
                                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        createdAlbumDirectories.append(url)
        return album
    }

    private func uniqueAlbumName(_ label: String) -> String {
        "AKR-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func manager(keys: [PrivateKey], current: PrivateKey) -> AlbumManager {
        let keyManager = DemoKeyManager(keys: keys)
        keyManager.currentKey = current
        return AlbumManager(keyManager: keyManager)
    }

    // MARK: - The defect

    /// The headline. An album written under key A must come back keyed by A even when
    /// the current key is B — the state every multi-device account reaches.
    func testAlbumFromScanIsKeyedByTheKeyThatEncryptedIt() throws {
        let name = uniqueAlbumName("owned-by-a")
        try seedLocalAlbum(named: name, key: keyA)

        let albumManager = manager(keys: [keyA, keyB], current: keyB)
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)

        guard let album = albums.first(where: { $0.name == name }) else {
            return XCTFail("""
                           No album came back under the name \(name). The scan found \
                           \(albums.count) album(s): \(albums.map(\.name)). An album whose name is \
                           still `Album_…` ciphertext is this bug: it was built with key B, which \
                           cannot decrypt a name key A wrote.
                           """)
        }
        XCTAssertEqual(album.key.keychainLabel, keyA.keychainLabel,
                       "The album was written with key A, so it must be keyed by A. It came back "
                       + "keyed by \(album.key.keychainLabel == keyB.keychainLabel ? "B, the current key" : "some other key").")
    }

    /// The same album must not change identity when the user's current key changes.
    /// `Album.id` is derived from the decrypted name, so a mis-keyed album silently
    /// becomes a different album — which is what orphans its settings and detaches it
    /// from its own CloudKit record.
    func testAlbumIdentityDoesNotDependOnTheCurrentKey() throws {
        let name = uniqueAlbumName("stable-id")
        try seedLocalAlbum(named: name, key: keyA)

        let underA = manager(keys: [keyA, keyB], current: keyA)
            .fetchAlbumsFromSources(includingHidden: true)
            .first { $0.key.keychainLabel == keyA.keychainLabel && $0.name == name }
        let underB = manager(keys: [keyA, keyB], current: keyB)
            .fetchAlbumsFromSources(includingHidden: true)
            .first { $0.name == name }

        XCTAssertNotNil(underA, "The album should resolve when its own key is current")
        XCTAssertNotNil(underB, """
                        The album vanished from the grid when the current key changed to B. Its \
                        name never decrypted, so it is in the list under an `Album_…` ciphertext \
                        name instead — present on disk, absent to the user.
                        """)
        XCTAssertEqual(underA?.id, underB?.id,
                       "One album on disk must have one identity regardless of which key is current")
    }

    /// Two albums, one per key, both present at once: the state the fix has to handle,
    /// as opposed to merely picking a different single key.
    func testEachAlbumResolvesToItsOwnKey() throws {
        let nameA = uniqueAlbumName("a-side")
        let nameB = uniqueAlbumName("b-side")
        try seedLocalAlbum(named: nameA, key: keyA)
        try seedLocalAlbum(named: nameB, key: keyB)

        let albums = manager(keys: [keyA, keyB], current: keyB)
            .fetchAlbumsFromSources(includingHidden: true)

        let resolvedA = albums.first { $0.name == nameA }
        let resolvedB = albums.first { $0.name == nameB }

        XCTAssertEqual(resolvedA?.key.keychainLabel, keyA.keychainLabel,
                       "The album written under A must resolve to A")
        XCTAssertEqual(resolvedB?.key.keychainLabel, keyB.keychainLabel,
                       "The album written under B must resolve to B")
    }

    /// An album whose key is genuinely absent must not be handed the current key.
    /// Attaching a key that cannot read it is what poisons its identity, its index and
    /// every subsequent write into it — a locked album has to stay locked.
    func testAlbumWithNoAvailableKeyIsNotHandedTheCurrentKey() throws {
        let name = uniqueAlbumName("foreign")
        try seedLocalAlbum(named: name, key: keyC)

        let albums = manager(keys: [keyA, keyB], current: keyB)
            .fetchAlbumsFromSources(includingHidden: true)

        let ciphertextNamed = albums.filter { $0.name.hasPrefix("Album_") }
        XCTAssertTrue(ciphertextNamed.isEmpty, """
                      \(ciphertextNamed.count) album(s) came back still carrying an `Album_…` \
                      ciphertext name, which means they were built with a key that cannot decrypt \
                      them. An album whose key is not on this device must be reported as locked, \
                      not handed the current key.
                      """)
    }
}
