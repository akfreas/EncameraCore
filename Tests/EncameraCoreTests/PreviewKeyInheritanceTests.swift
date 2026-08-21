//
//  PreviewKeyInheritanceTests.swift
//  EncameraCoreTests
//
//  A preview is encrypted with the key of the media it was made from.
//
//  `createPreview` decrypts its source through the discovery sweep, so it opens a file
//  with whatever key actually encrypted it, and the preview it writes has to carry that
//  same key rather than the album's — an album can hold media a second key wrote.
//
//  A CloudKit `EncMedia` record carries ONE key fingerprint and TWO assets, so an item
//  whose two halves are under different keys cannot be described by its own record.
//  Holding the invariant here keeps that true by construction, so nothing downstream
//  has to check it.
//
//  Only the divergent case is covered, and deliberately: when a file is under its own
//  album's key there is no key to distinguish, so a preview written with the album key
//  and one written with the source key are the same bytes, and no assertion over that
//  fixture can tell a correct implementation from a broken one.
//

import XCTest
import UIKit
@testable import EncameraCore

final class PreviewKeyInheritanceTests: XCTestCase {

    private let albumKey = PrivateKey(name: AppConstants.defaultKeyName,
                                      keyBytes: Array(repeating: 0xB2, count: 32),
                                      creationDate: Date(timeIntervalSince1970: 2_000))
    private let mediaKey = PrivateKey(name: AppConstants.defaultKeyName,
                                      keyBytes: Array(repeating: 0xA1, count: 32),
                                      creationDate: Date(timeIntervalSince1970: 1_000))

    private var album: Album!

    override func setUpWithError() throws {
        album = Album(name: "preview-key-\(UUID().uuidString.prefix(8))",
                      storageOption: .local,
                      creationDate: Date(),
                      key: albumKey)
        try album.storageOption.modelForType.init(album: album).initializeDirectories()
    }

    override func tearDownWithError() throws {
        let model = album.storageOption.modelForType.init(album: album)
        try? FileManager.default.removeItem(at: model.baseURL)
        try? FileManager.default.removeItem(at: model.previewURLForMedia(withID: mediaID))
    }

    private let mediaID = "diverged-media"

    private func tinyPNG() -> Data {
        let size = CGSize(width: 8, height: 8)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    /// The headline. The album is keyed B; the file inside it is under A — the ordinary
    /// state of any album touched by a second key. Its preview must come out under A.
    func testPreviewInheritsTheKeyOfTheMediaItWasMadeFrom() async throws {
        let model = album.storageOption.modelForType.init(album: album)
        let encURL = model.driveURLForMedia(withID: mediaID, type: .photo)
        let source = CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: mediaID)
        _ = try await SecretFileHandlerV2(keyBytes: mediaKey.keyBytes,
                                          source: source,
                                          targetURL: encURL).encryptWithMetadata(EncryptedFileMetadata())

        let keyManager = DemoKeyManager(keys: [albumKey, mediaKey])
        keyManager.currentKey = albumKey
        let albumManager = AlbumManager(keyManager: keyManager)
        let access = DiskFileAccess()
        await access.configure(for: album, albumManager: albumManager)

        let encrypted = EncryptedMedia(source: .url(encURL), mediaType: .photo, id: mediaID)
        _ = try await access.createPreview(for: encrypted)

        let previewURL = model.previewURLForMedia(withID: mediaID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path),
                      "precondition: a preview was written")

        let underMediaKey = await KeyDiscovery.proveFirstBlock(of: previewURL, with: mediaKey)
        let underAlbumKey = await KeyDiscovery.proveFirstBlock(of: previewURL, with: albumKey)

        XCTAssertEqual(underMediaKey, .proved,
                       "The media is under A, so its preview must be too. A preview under the "
                       + "album's key is an asset its own item's key cannot open.")
        XCTAssertNotEqual(underAlbumKey, .proved,
                          "and it must not be under the album key, which is what produced the "
                          + "divergent pair in the first place")
    }

}
