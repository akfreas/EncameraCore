//
//  CloudKitStorageDetailsTests.swift
//  EncameraCoreTests
//
//  `CloudKitFileAccess.storageDetails` and `evictLocalCopy` against a mock store
//  behind a real coordinator and a real blob cache. The cloud side is where the
//  info screen's answers are least obvious — the format is unknowable until
//  something is cached, and eviction has to reach cached bytes without touching
//  the records — so those are the statements pinned here.
//

import XCTest
import CloudKit
import UIKit
@testable import EncameraCore

final class CloudKitStorageDetailsTests: XCTestCase {

    private func makeAlbum() -> Album {
        let key = PrivateKey(name: "test-key",
                             keyBytes: Array(repeating: UInt8(9), count: 32),
                             creationDate: Date())
        return Album(name: "Storage-\(UUID().uuidString)",
                     storageOption: .cloudKit,
                     creationDate: Date(),
                     key: key)
    }

    private func makeAccess(album: Album, store: MockCloudKitMediaStore) async -> CloudKitFileAccess {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        return await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)
    }

    private func encURL(for album: Album, id: String) -> URL {
        CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    private func makeENC2(album: Album, id: String, data: Data) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id)-\(UUID().uuidString).enc")
        let cleartext = CleartextMedia(source: .data(data), mediaType: .photo, id: id)
        let handler = SecretFileHandlerV2(keyBytes: album.key.keyBytes, source: cleartext, targetURL: tmp)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try Data(contentsOf: tmp)
    }

    private func media(album: Album, id: String) throws -> InteractableMedia<EncryptedMedia> {
        try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .photo, id: id)
        ])
    }

    // MARK: -

    /// Before anything is downloaded there is nothing local and nothing to sniff.
    /// The format must come back unknown rather than being assumed to be ENC2 —
    /// migrated ENC1 blobs live in CloudKit too, and only their bytes can tell
    /// them apart.
    func testUncachedCloudItemReportsNoLocalCopyAndNoFormat() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let id = UUID().uuidString
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))

        let details = await access.storageDetails(for: try media(album: album, id: id))

        XCTAssertEqual(details?.storageType, .cloudKit)
        XCTAssertTrue(details?.isRemotelyBacked ?? false)
        XCTAssertNil(details?.localBytes, "nothing has been downloaded")
        XCTAssertNil(details?.format, "the format cannot be named without the bytes")
        XCTAssertFalse(details?.canEvictLocalCopy ?? true, "there is no local copy to drop")
    }

    /// Once a load has cached the blob, the cached bytes are reported and the
    /// format can be sniffed off them — the state the info screen is almost
    /// always opened in, since the user got there by viewing the media.
    func testCachedCloudItemReportsItsCachedBytesAndSniffedFormat() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let id = UUID().uuidString
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))

        let ciphertext = try await makeENC2(album: album, id: id, data: Data("cached round trip".utf8))
        store.blobContents = ciphertext

        let item = try media(album: album, id: id)
        _ = try await access.loadMedia(media: item, progress: { _ in })

        let details = await access.storageDetails(for: item)

        XCTAssertEqual(details?.localBytes, Int64(ciphertext.count),
                       "the cached copy's size is the ciphertext's own")
        XCTAssertEqual(details?.format, .v2)
        XCTAssertNil(details?.chunkCount, "an unchunked blob has no chunk row")
        XCTAssertTrue(details?.canEvictLocalCopy ?? false)
    }

    /// Eviction has to actually free the bytes. A no-op that reported success
    /// would leave ciphertext on disk while telling the user it was reclaimed —
    /// so this asserts on what the next read finds, not on the call returning.
    func testEvictingDropsTheCachedCopyWithoutDeletingTheRecord() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let id = UUID().uuidString
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))

        store.blobContents = try await makeENC2(album: album, id: id, data: Data("evict me".utf8))
        let item = try media(album: album, id: id)
        _ = try await access.loadMedia(media: item, progress: { _ in })
        let before = await access.storageDetails(for: item)
        XCTAssertNotNil(before?.localBytes, "precondition: cached")

        try await access.evictLocalCopy(for: item)

        let after = await access.storageDetails(for: item)
        XCTAssertNil(after?.localBytes, "the cached ciphertext must be gone")
        XCTAssertFalse(after?.canEvictLocalCopy ?? true)
        XCTAssertTrue(store.deleteCalls.isEmpty, "eviction must never delete the CloudKit record")

        // And the media is still openable, because only the local copy went.
        let reloaded = try await access.loadMedia(media: item, progress: { _ in })
        XCTAssertEqual(reloaded.underlyingMedia.first?.data, Data("evict me".utf8))
    }

    /// The blob had to be re-fetched after eviction. Without this the previous
    /// test would still pass against a cache that quietly kept serving the file.
    func testEvictionForcesTheNextLoadToRefetch() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let id = UUID().uuidString
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))

        store.blobContents = try await makeENC2(album: album, id: id, data: Data("refetch".utf8))
        let item = try media(album: album, id: id)

        _ = try await access.loadMedia(media: item, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)
        _ = try await access.loadMedia(media: item, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1, "precondition: the cache is serving the second read")

        try await access.evictLocalCopy(for: item)

        _ = try await access.loadMedia(media: item, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 2, "an evicted blob must come back over the network")
    }
}
