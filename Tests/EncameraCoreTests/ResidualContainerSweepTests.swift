//
//  ResidualContainerSweepTests.swift
//  EncameraCoreTests
//
//  The erase step that names nothing.
//
//  Every other step in `EraserUtils` erases a surface someone registered, and the
//  gap that leaves is not hypothetical: the CloudKit adapter wrote a copy of every
//  fetched chunk into a tmp directory that no erase step and no verifier knew
//  about, so "Erase All Data" left one file per chunk of every video ever played.
//  These tests are about the sweep that does not need to be told.
//

import XCTest
@testable import EncameraCore

final class ResidualContainerSweepTests: XCTestCase {

    private var root: URL!
    private let eraser = DefaultLocalDataEraser(keyManager: DemoKeyManager(),
                                                fileAccess: InteractableMediaFileAccess(),
                                                keyDeletionScope: .deviceLocal)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func seed(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: 32).write(to: url)
        return url
    }

    /// Everything under the root goes, at any depth, whatever it is called.
    func testSweepRemovesEveryFileUnderTheRootAtAnyDepth() throws {
        let planted = [
            "Documents/album/photo.encrypted",
            "Library/Caches/CloudKitBlobs/hash/blob#1",
            "Library/Application Support/EncameraAnalytics/events.sqlite",
            "tmp/ckassets/ckasset-1234-encChunk",
            "tmp/decrypted/movie.mov",
            "Library/Caches/a/b/c/d/e/deeply-nested.bin",
            "loose-file-at-the-root.bin"
        ]
        for path in planted { try seed(path) }

        eraser.eraseResidualContainerFiles(roots: [root])

        for path in planted {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                           "\(path) survived the sweep")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [],
                       "the root should be empty")
    }

    /// `Preferences` is `cfprefsd`'s, not ours. Deleting the plists underneath a
    /// running preferences daemon corrupts the domain rather than clearing it —
    /// `eraseUserDefaults()` is how those are cleared.
    func testSweepLeavesThePreferencesDirectoryAlone() throws {
        try seed("Library/Preferences/me.freas.encamera.plist")
        try seed("Library/Caches/junk.bin")

        eraser.eraseResidualContainerFiles(roots: [root])

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Library/Preferences/me.freas.encamera.plist").path),
            "preferences must survive the file sweep")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Library/Caches/junk.bin").path))
    }

    /// The roots have to resolve to something real, or every test above passes
    /// against a sweep that runs over nothing.
    func testContainerRootsIncludeTheAppHomeDirectory() {
        let roots = EraserUtils.containerRoots.map(\.path)
        XCTAssertTrue(roots.contains(URL(fileURLWithPath: NSHomeDirectory()).path),
                      "the sweep must cover the app's own container; roots were \(roots)")
    }
}
