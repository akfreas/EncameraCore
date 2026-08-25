//
//  AlbumDirectoryDiscoveryTests.swift
//  EncameraCoreTests
//
//  What `enumerateAlbumsDirectory` counts as an album on disk.
//
//  Driven through a test-only `DataStorageModel` rather than one of the shipping
//  three: the rule under test lives entirely in the protocol extension, and both
//  real models resolve `rootURL` to somewhere a test must not write — the app's
//  Documents directory for `.local`, the ubiquity container for `.icloud`. A
//  conforming type whose `rootURL` is a scratch directory exercises the real
//  implementation with nothing stubbed out.
//

import XCTest
@testable import EncameraCore

/// Substitutes only `rootURL`. Everything the assertions touch —
/// `albumsURL`, `enumerateAlbumsDirectory` — is the production protocol
/// extension, unmodified.
private struct ScratchStorageModel: DataStorageModel {
    nonisolated(unsafe) static var scratchRoot: URL!

    static var rootURL: URL { scratchRoot }

    var storageType: StorageType { .local }
    var album: Album
    var baseURL: URL { Self.albumsURL.appendingPathComponent(album.encryptedPathComponent) }

    init(album: Album) {
        self.album = album
    }
}

final class AlbumDirectoryDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("AlbumDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ScratchStorageModel.scratchRoot = root
    }

    override func tearDownWithError() throws {
        ScratchStorageModel.scratchRoot = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func seedDirectory(_ name: String, at parent: URL) throws {
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func seedAlbumsSubdirectory() throws -> URL {
        let albums = root.appendingPathComponent("albums", isDirectory: true)
        try FileManager.default.createDirectory(at: albums, withIntermediateDirectories: true)
        return albums
    }

    private func discoveredNames() -> Set<String> {
        Set(ScratchStorageModel.enumerateAlbumsDirectory().map { $0.lastPathComponent })
    }

    /// The bug: albums created before album-name encryption have no `Album_`
    /// prefix, so the prefix filter dropped them and the user's grid came up
    /// empty while the directories sat in iCloud Drive, intact.
    func testDiscoversLegacyPlaintextAlbumDirectoriesAtRoot() throws {
        try seedDirectory("met", at: root)
        try seedDirectory("koti", at: root)

        XCTAssertEqual(discoveredNames(), ["met", "koti"])
    }

    func testDiscoversEncryptedAlbumDirectoriesUnderAlbumsSubdir() throws {
        try seedDirectory("Album_aaa", at: try seedAlbumsSubdirectory())

        XCTAssertEqual(discoveredNames(), ["Album_aaa"])
    }

    /// Both layouts at once: an already-migrated album and one the migration has
    /// not reached yet must both appear, and `albums` itself must not be mistaken
    /// for an album now that the prefix no longer excludes it.
    func testDiscoversBothLayoutsAndNeverTheAlbumsContainerItself() throws {
        try seedDirectory("Album_aaa", at: try seedAlbumsSubdirectory())
        try seedDirectory("met", at: root)

        XCTAssertEqual(discoveredNames(), ["Album_aaa", "met"])
    }

    func testExcludesNonAlbumSiblings() throws {
        try seedDirectory(AppConstants.previewDirectory, at: root)
        try seedDirectory("thumbs", at: root)
        try seedDirectory("RevenueCat", at: root)
        try seedDirectory("Inbox", at: root)
        try seedDirectory("met", at: root)

        XCTAssertEqual(discoveredNames(), ["met"])
    }

    func testExcludesFilesAndDotDirectories() throws {
        try seedDirectory(".Trash", at: root)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent("loose.encimage").path, contents: Data()))
        try seedDirectory("met", at: root)

        XCTAssertEqual(discoveredNames(), ["met"])
    }

    /// A root copy left behind by a failed move must not double the album in the
    /// grid — the migrated copy under `albums/` wins.
    func testDeduplicatesAnAlbumPresentInBothLayouts() throws {
        let albums = try seedAlbumsSubdirectory()
        try seedDirectory("met", at: albums)
        try seedDirectory("met", at: root)

        let discovered = ScratchStorageModel.enumerateAlbumsDirectory()
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.deletingLastPathComponent().standardizedFileURL,
                       albums.standardizedFileURL)
    }
}
