import XCTest
@testable import EncameraCore

final class AlbumsDirectoryMigrationUtilTests: XCTestCase {

    private var fixtureRoot: URL!
    private var rootURL: URL!
    private var albumsURL: URL!
    private var util: AlbumsDirectoryMigrationUtil!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureRoot = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("AlbumsDirMigrationTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = fixtureRoot.appendingPathComponent("root", isDirectory: true)
        albumsURL = rootURL.appendingPathComponent("albums", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let suiteName = "AlbumsDirMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        util = AlbumsDirectoryMigrationUtil(userDefaults: defaults)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
        fixtureRoot = nil
        rootURL = nil
        albumsURL = nil
        util = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func seedAlbum(_ name: String, at parent: URL, withFile fileName: String = "sentinel.bin") throws -> URL {
        let albumURL = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: albumURL, withIntermediateDirectories: true)
        let filePath = albumURL.appendingPathComponent(fileName)
        XCTAssertTrue(FileManager.default.createFile(atPath: filePath.path, contents: Data([0x01, 0x02, 0x03])))
        return albumURL
    }

    private func seedPlainDirectory(_ name: String, at parent: URL) throws -> URL {
        let dirURL = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        return dirURL
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Tests

    func testMovesAlbumPrefixedDirectoriesIntoAlbumsSubdir() throws {
        _ = try seedAlbum("Album_aaa", at: rootURL)
        _ = try seedAlbum("Album_bbb", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertFalse(exists(rootURL.appendingPathComponent("Album_aaa")))
        XCTAssertFalse(exists(rootURL.appendingPathComponent("Album_bbb")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_aaa")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_bbb")))

        // Contents preserved.
        let sentinel = albumsURL.appendingPathComponent("Album_aaa").appendingPathComponent("sentinel.bin")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([0x01, 0x02, 0x03]))
    }

    func testLeavesNonAlbumSiblingsUntouched() throws {
        _ = try seedPlainDirectory("preview_thumbnails", at: rootURL)
        _ = try seedPlainDirectory("RevenueCat", at: rootURL)
        _ = try seedAlbum("Album_xxx", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(rootURL.appendingPathComponent("preview_thumbnails")))
        XCTAssertTrue(exists(rootURL.appendingPathComponent("RevenueCat")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_xxx")))
    }

    func testIsIdempotent() throws {
        _ = try seedAlbum("Album_once", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))
        // Second call: nothing to move, still succeeds.
        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_once")))
        XCTAssertFalse(exists(rootURL.appendingPathComponent("Album_once")))
    }

    func testSkipsWhenDestinationAlreadyExists() throws {
        // Simulate crash-recovery state: a partially-migrated album exists at dest,
        // and a stale copy still sits at root. Migration must not clobber the dest.
        _ = try seedAlbum("Album_dup", at: rootURL, withFile: "stale.bin")
        try FileManager.default.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        _ = try seedAlbum("Album_dup", at: albumsURL, withFile: "fresh.bin")

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        // Dest retains its existing content.
        let freshFile = albumsURL.appendingPathComponent("Album_dup").appendingPathComponent("fresh.bin")
        XCTAssertTrue(exists(freshFile))
        let staleInDest = albumsURL.appendingPathComponent("Album_dup").appendingPathComponent("stale.bin")
        XCTAssertFalse(exists(staleInDest))
        // Stale root copy remains; operator can resolve manually.
        XCTAssertTrue(exists(rootURL.appendingPathComponent("Album_dup")))
    }

    func testLeavesTheRootAloneWhenThereIsNothingToMigrate() throws {
        _ = try seedPlainDirectory("thumbs", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertFalse(exists(albumsURL), "an empty albums/ planted in iCloud Drive reads as legacy data to the existing-data probe")
    }

    func testReturnsFalseWhenAlbumsURLCannotBeCreated() throws {
        _ = try seedAlbum("Album_good", at: rootURL)
        // Point albumsURL at a non-creatable location — a file where a directory should be.
        let blockedAlbumsURL = rootURL.appendingPathComponent("blocked")
        XCTAssertTrue(FileManager.default.createFile(atPath: blockedAlbumsURL.path, contents: Data()))

        XCTAssertFalse(util.performMigration(at: rootURL, into: blockedAlbumsURL))

        // Source album untouched — safe for next-launch retry.
        XCTAssertTrue(exists(rootURL.appendingPathComponent("Album_good")))
    }

    func testIgnoresAlbumAlreadyUnderAlbumsURL() throws {
        try FileManager.default.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        _ = try seedAlbum("Album_inplace", at: albumsURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_inplace")))
    }

    /// Albums created before album-name encryption sit at the storage root under
    /// their PLAINTEXT name — no `Album_` prefix. They are still albums and still
    /// belong under `albums/`.
    func testMovesLegacyPlaintextAlbumDirectoriesIntoAlbumsSubdir() throws {
        _ = try seedAlbum("met", at: rootURL)
        _ = try seedAlbum("koti", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertFalse(exists(rootURL.appendingPathComponent("met")))
        XCTAssertFalse(exists(rootURL.appendingPathComponent("koti")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("met")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("koti")))

        let sentinel = albumsURL.appendingPathComponent("met").appendingPathComponent("sentinel.bin")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([0x01, 0x02, 0x03]))
    }

    /// The upgrade path this fix exists for: a device that ran the V1 migration
    /// recorded it as done while leaving every plaintext-named album at the root.
    /// Reusing the V1 flag key would strand those devices forever — the widened
    /// migration would be skipped before it ever enumerated anything.
    func testADeviceThatCompletedTheV1MigrationIsNotConsideredMigrated() throws {
        let suiteName = "AlbumsDirMigrationV1Flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([StorageType.local.rawValue, StorageType.icloud.rawValue],
                     forKey: "completedAlbumsDirectoryMigrationV1")

        let util = AlbumsDirectoryMigrationUtil(userDefaults: defaults)

        XCTAssertFalse(util.hasMigrated(.local))
        XCTAssertFalse(util.hasMigrated(.icloud))
    }

    /// The flag still has to work as a flag: once the widened migration records a
    /// storage type, it is not repeated.
    func testRecordsCompletionUnderTheCurrentFlagKey() throws {
        let suiteName = "AlbumsDirMigrationV2Flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let util = AlbumsDirectoryMigrationUtil(userDefaults: defaults)
        XCTAssertFalse(util.hasMigrated(.local))

        util.markMigrated(.local)

        XCTAssertTrue(util.hasMigrated(.local))
        XCTAssertFalse(util.hasMigrated(.icloud))
    }

    func testIgnoresFilesThatLookLikeAlbums() throws {
        let bogus = rootURL.appendingPathComponent("Album_justAFile")
        XCTAssertTrue(FileManager.default.createFile(atPath: bogus.path, contents: Data()))

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(bogus))
        XCTAssertFalse(exists(albumsURL.appendingPathComponent("Album_justAFile")))
    }
}
