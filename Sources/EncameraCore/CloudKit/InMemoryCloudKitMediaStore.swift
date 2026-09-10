//
//  InMemoryCloudKitMediaStore.swift
//  EncameraCore
//
//  A deterministic, in-memory `CloudKitMediaStoring` for UI tests (`-CloudKitMockMode`)
//  and offline verification. Stores ciphertext blobs and index fields in memory —
//  never touches the network or an iCloud account.
//

import Foundation
import CloudKit

public final class InMemoryCloudKitMediaStore: CloudKitMediaStoring, @unchecked Sendable {

    private struct Stored {
        var metadata: CloudKitMediaMetadata
        var blob: Data
        var thumbnail: Data
        var keyFingerprint: String
    }

    private let lock = NSLock()
    private var records: [String: Stored] = [:]
    private var albums: [String: CloudKitAlbumMetadata] = [:]
    /// Deletions the change feed still has to report. The real zone reports a
    /// deleted record once, by id and type; a fake that just drops the entry would
    /// let a delete vanish without any consumer ever hearing about it.
    private var deletedAlbumIDs: [String] = []
    private var deletedRecordNames: [String] = []
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// Artificial per-upload delay, for UI tests that need a migration to stay in
    /// flight long enough to observe. Defaults to zero, so every existing caller —
    /// including all the unit tests — is unaffected.
    public var uploadDelay: Duration = .zero

    /// Transport for chunked blobs. When an upload carries `chunkCount > 0` the
    /// ciphertext is split into chunks via this store instead of being held as a
    /// monolithic blob — mirroring what `CloudKitMediaStore` does in production.
    /// Defaults to `InMemoryChunkedBlobStore()` so the mock is self-contained;
    /// callers that need the same instance reachable from a coordinator should
    /// inject a shared one.
    public let chunkStore: ChunkedBlobStoring

    public init(chunkStore: ChunkedBlobStoring = InMemoryChunkedBlobStore()) {
        self.chunkStore = chunkStore
    }

    public init(uploadDelay: Duration, chunkStore: ChunkedBlobStoring = InMemoryChunkedBlobStore()) {
        self.uploadDelay = uploadDelay
        self.chunkStore = chunkStore
    }

    public func upload(_ item: CloudKitMediaUpload,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        if uploadDelay > .zero {
            try await Task.sleep(for: uploadDelay)
        }

        // Chunked items delegate their payload to the chunk store, mirroring
        // CloudKitMediaStore's production path. The monolithic blob is left
        // empty — reads go through the chunk store, not fetchBlob.
        let blob: Data
        if item.chunkCount > 0 {
            try await chunkStore.uploadChunks(enc3FileURL: item.encryptedFileURL,
                                              mediaRecordName: item.recordName,
                                              progress: progress)
            blob = Data()
        } else {
            blob = (try? Data(contentsOf: item.encryptedFileURL)) ?? Data()
        }

        let thumb = item.encryptedThumbURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let tag = "tag-\(item.recordName)"
        let metadata = CloudKitMediaMetadata(descriptor: item.descriptor,
                                             creationDeviceID: DeviceIdentity.current,
                                             schemaVersion: item.schemaVersion,
                                             recordChangeTag: tag)
        // Keyed by recordName so a Live Photo's two components don't collide.
        locked {
            records[item.recordName] = Stored(metadata: metadata,
                                              blob: blob,
                                              thumbnail: thumb,
                                              keyFingerprint: item.keyFingerprint)
        }
        progress(1.0)
        return CloudKitMediaRef(recordName: item.recordName, recordChangeTag: tag)
    }

    /// Seeds an album and `mediaCount` live media records directly, as if another
    /// device had written them. Without this the mock binds an EMPTY zone, so a UI
    /// test that stubs a probe census of N is driving a delete over nothing: the
    /// sweep deletes zero records and passes exactly as it would against a
    /// coordinator that deleted nothing at all.
    ///
    /// `includeAlbumRecord: false` seeds the media with NO album record — the media
    /// whose `EncAlbum` another device hard-deleted, or that a stale query index has
    /// not caught up with. `fetchAllAlbums` then enumerates nothing while the census
    /// still counts the records, which is the shape of the vacuous-success bug.
    public func seedRecords(albumID: String,
                            mediaCount: Int,
                            keyFingerprint: String = "seeded-fingerprint",
                            includeAlbumRecord: Bool = true) {
        locked {
            if includeAlbumRecord {
                albums[albumID] = CloudKitAlbumMetadata(
                    albumID: albumID, encName: "enc-\(albumID)", createdAt: Date(),
                    isHidden: false,
                    schemaVersion: CloudKitSchema.currentSchemaVersion,
                    keyFingerprint: keyFingerprint,
                    recordChangeTag: "albumtag-\(albumID)"
                )
            }
            for index in 0..<mediaCount {
                let recordName = "\(albumID)-seeded-\(index)"
                let descriptor = CloudKitMediaRecordDescriptor(
                    albumID: albumID, mediaID: recordName, recordName: recordName,
                    mediaType: .photo, createdAt: Date(), sizeBytes: 1, keyFingerprint: ""
                )
                let metadata = CloudKitMediaMetadata(descriptor: descriptor,
                                                     creationDeviceID: "seeded-device",
                                                     schemaVersion: CloudKitSchema.currentSchemaVersion,
                                                     recordChangeTag: "tag-\(recordName)")
                records[recordName] = Stored(metadata: metadata,
                                             blob: Data(),
                                             thumbnail: Data(),
                                             keyFingerprint: keyFingerprint)
            }
        }
    }

    /// Record names the zone still holds live, so a test can assert what a delete
    /// actually removed rather than inferring it from navigation.
    public var liveRecordNames: [String] {
        locked { records.values.map(\.metadata.recordName).sorted() }
    }

    public func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata] {
        locked { records.values.map { $0.metadata }.filter { $0.albumID == albumID } }
    }

    public func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata? {
        locked { records[recordName]?.metadata }
    }

    public func fetchBlob(recordName: String,
                          to destination: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let stored = locked({ records[recordName] }) else { throw CloudKitMediaStoreError.notFound }
        try stored.blob.write(to: destination)
        progress(1.0)
    }

    public func fetchThumbnail(recordName: String, to destination: URL) async throws {
        guard let stored = locked({ records[recordName] }) else { throw CloudKitMediaStoreError.notFound }
        try stored.thumbnail.write(to: destination)
    }

    public func delete(recordName: String) async throws {
        locked {
            guard records.removeValue(forKey: recordName) != nil else { return }
            deletedRecordNames.append(recordName)
        }
    }

    // MARK: Albums (chunk 13)

    public func saveAlbum(_ album: CloudKitAlbumUpload) async throws {
        let tag = "albumtag-\(album.albumID)"
        locked {
            albums[album.albumID] = CloudKitAlbumMetadata(
                albumID: album.albumID, encName: album.encName, createdAt: album.createdAt,
                isHidden: album.isHidden, schemaVersion: album.schemaVersion,
                keyFingerprint: album.keyFingerprint.isEmpty ? nil : album.keyFingerprint,
                recordChangeTag: tag
            )
        }
    }

    public func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] {
        locked { Array(albums.values) }
    }

    /// Always `.counted`: an in-memory store knows its own contents exactly, so an
    /// empty result really is an empty zone.
    public func fetchFingerprintCensus() async throws -> CloudKitFingerprintCensus {
        locked {
            var counts: [String: Int] = [:]
            for stored in records.values {
                guard !stored.keyFingerprint.isEmpty else { continue }
                counts[stored.keyFingerprint, default: 0] += 1
            }
            return .counted(mediaCount: records.count, fingerprints: counts)
        }
    }

    public func deleteAlbum(albumID: String) async throws {
        locked {
            guard albums.removeValue(forKey: albumID) != nil else { return }
            deletedAlbumIDs.append(albumID)
            // Model the server-side `.deleteSelf` cascade: the album's media go with
            // it. Without this the fake would keep reporting an album's records as
            // live after the album was deleted, which the real zone never does.
            for (recordName, stored) in records where stored.metadata.albumID == albumID {
                records[recordName] = nil
                deletedRecordNames.append(recordName)
            }
        }
    }

    public func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        let (all, albumsNow, goneAlbums, goneRecords) = locked {
            (Array(records.values), Array(albums.values), deletedAlbumIDs, deletedRecordNames)
        }
        return CloudKitChangeSet(changed: all.map { $0.metadata },
                                 deleted: goneRecords,
                                 changedAlbums: albumsNow,
                                 deletedAlbumIDs: goneAlbums,
                                 token: nil,
                                 moreComing: false)
    }

    public func loadChangeToken() async -> CKServerChangeToken? { nil }

    public func hasChangeToken() async -> Bool { false }

    public func commitChangeToken(_ token: CKServerChangeToken?) async {}

    public func resetChangeToken() async {}

    public func recreateZone() async throws {}

    public func ensureZoneExists() async throws {}

    public func registerZoneSubscription() async throws {}

    public func cancelAll() {}

    public func accountAvailable() async -> Bool { true }
}
