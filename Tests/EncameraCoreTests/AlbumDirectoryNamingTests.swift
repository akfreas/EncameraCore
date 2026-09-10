//
//  AlbumDirectoryNamingTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class AlbumDirectoryNamingTests: XCTestCase {

    func testEncryptedAndPlaintextAlbumNamesAreAlbums() {
        XCTAssertTrue(AlbumDirectoryNaming.isAlbumDirectoryName("Album_c29tZSBuYW1l"))
        XCTAssertTrue(AlbumDirectoryNaming.isAlbumDirectoryName("Holiday 2019"))
    }

    func testKnownSiblingsAreNotAlbums() {
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName("albums"))
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName("RevenueCat"))
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName(".Trash"))
    }

    func testRevenueCatCachesAreNotAlbums() {
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName("me.freas.encamera.revenuecat.etags"),
                       "the SDK's etag cache was adopted as an album on the launch after an erase")
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName("me.freas.encamera-debug.RevenueCat.diagnostics"))
    }
}
