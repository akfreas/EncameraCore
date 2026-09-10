import XCTest
import Sodium
@testable import EncameraCore

final class AlbumManagerChunkOrphanTests: XCTestCase {

    private let testKey = PrivateKey(name: "test", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))

    private func makeCloudKitAlbum() -> Album {
        Album(name: "ChunkOrphanAlbum", storageOption: .cloudKit, creationDate: Date(), key: testKey)
    }

    private func albumIDHash(for album: Album) -> String? {
        SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)
    }

    /// When `fetchMetadata` throws (offline, rate-limited), `deleteCloudKitAlbumRecord`
    /// must NOT proceed to `store.deleteAlbum`. If it did, the `.deleteSelf` cascade
    /// would destroy every `EncMedia` record while the chunk records — which live in a
    /// separate zone with no references — remain unqueued and permanently orphaned.
    /// The album must stay in the delete queue so the reconciler retries the whole
    /// sequence on its next pass.
    func testDeleteAbortedWhenChunkEnumerationFails() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchMetadataError = NSError(domain: "CKErrorDomain", code: 1, userInfo: nil)

        let previousMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in store }
        defer { CloudKitStoreProvider.makeStore = previousMakeStore }

        let keyManager = DemoKeyManager()
        let manager = AlbumManager(keyManager: keyManager)
        let album = makeCloudKitAlbum()

        manager.delete(album: album)

        // The Task inside deleteCloudKitAlbumRecord runs asynchronously. Wait for the
        // mock to record the fetchMetadata call, which proves the Task reached the
        // error path.
        let deadline = Date().addingTimeInterval(5)
        while store.fetchMetadataCalls.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(store.fetchMetadataCalls.isEmpty,
                       "deleteCloudKitAlbumRecord must attempt to enumerate chunk members")

        // Give a generous window for any follow-up work that should NOT happen.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(store.deletedAlbumCalls.isEmpty,
                      "A failed chunk enumeration must NOT proceed to deleteAlbum — chunks would be permanently orphaned")

        // The album must remain in the delete queue for the reconciler to retry.
        guard let hash = albumIDHash(for: album) else {
            XCTFail("keyedHash must succeed for a 32-byte key")
            return
        }
        let queue = CloudKitAlbumDeleteQueue()
        XCTAssertTrue(queue.pending().contains(hash),
                      "The album must remain queued so the reconciler retries the full delete sequence")

        // Clean up: remove the test entry from the shared queue.
        queue.remove(hash)
    }
}
