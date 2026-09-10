//
//  CachedChunkedBlobStore.swift
//  EncameraCore
//
//  A `ChunkedBlobStoring` decorator that persists fetched chunks in the existing
//  `CloudKitBlobCache`, keyed by chunk record name — so a re-watched video does
//  not re-download, across relaunches. `StreamingChunkSource`'s in-memory LRU
//  stays the hot layer on top of this; the blob cache's change-tag validation
//  and byte-cap LRU are reused verbatim.
//

import Foundation

public final class CachedChunkedBlobStore: ChunkedBlobStoring, DebugPrintable, @unchecked Sendable {

    private let store: ChunkedBlobStoring
    private let cache: CloudKitBlobCache
    private let albumID: String
    /// Content-derived tag for cache validation — typically the ENC3 header's
    /// `fileID` (random per encryption, base64-encoded). A re-uploaded video gets
    /// a new fileID, so cached chunks from the previous upload miss cleanly.
    /// `nil` skips the cache entirely to avoid serving stale bytes.
    private let validationTag: String?

    public init(store: ChunkedBlobStoring,
                cache: CloudKitBlobCache,
                albumID: String,
                validationTag: String?) {
        self.store = store
        self.cache = cache
        self.albumID = albumID
        self.validationTag = validationTag
    }

    @discardableResult
    public func uploadChunks(enc3FileURL: URL,
                             mediaRecordName: String,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
        try await store.uploadChunks(enc3FileURL: enc3FileURL, mediaRecordName: mediaRecordName, progress: progress)
    }

    /// Reads through the cache, but never writes through it.
    ///
    /// Persisting a chunk costs a filesystem operation on 4 MiB plus the cache
    /// actor's byte-cap eviction pass. Doing that before returning put all of it
    /// between CloudKit and AVFoundation on every miss, serialized behind one actor
    /// shared with the rest of the app, while the player waits.
    ///
    /// The cached copy only saves a future re-download; playing the video is the
    /// job. So the bytes go back to the caller the moment they arrive and the file
    /// lands in the cache behind them, where being slow or failing outright costs
    /// nothing but a later re-fetch.
    public func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
        let chunkRecordName = ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: index)
        // A nil validationTag means the caller could not determine the current
        // content version — skip the cache entirely rather than serving bytes that
        // may belong to a previous upload.  Chunk records are never delta-synced,
        // so unlike monolithic blobs there is no "next sync" to fix a nil tag.
        if let validationTag {
            let cachedURL = await cache.cachedURL(recordName: chunkRecordName, changeTag: validationTag)
            if let cachedURL, let data = try? Data(contentsOf: cachedURL) {
                return data
            }
        }
        let chunk = try await store.fetchChunkStaged(mediaRecordName: mediaRecordName, index: index)
        persistInBackground(chunk, as: chunkRecordName)
        return chunk.data
    }

    /// Moves a fetched chunk into the blob cache off the playback path.
    ///
    /// Takes over ownership of `chunk.stagedFileURL`: the file the store already
    /// wrote becomes the cache's copy, so a miss costs no re-serialization of the
    /// bytes. A store with no file of its own gets one written here instead.
    private func persistInBackground(_ chunk: FetchedChunk, as chunkRecordName: String) {
        let cache = cache
        let albumID = albumID
        let validationTag = validationTag
        Task.detached(priority: .utility) { [weak self] in
            let staged = chunk.stagedFileURL
            let source = staged ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("chunkcache-\(UUID().uuidString)")
            // This file is ours for the rest of the task, whether the store handed it
            // over or it was written here. A successful move leaves nothing to remove;
            // every other path — a write failure, a cross-volume copy, a rejected
            // store — is cleaned up here rather than leaking one file per chunk.
            defer { try? FileManager.default.removeItem(at: source) }
            do {
                if staged == nil { try chunk.data.write(to: source) }
                try await cache.store(recordName: chunkRecordName,
                                      changeTag: validationTag,
                                      albumID: albumID,
                                      moving: source)
            } catch {
                self?.printDebug("fetchChunk cache store FAILED chunk=\(chunkRecordName) raw=\(error)")
            }
        }
    }

    public func delete(mediaRecordName: String, chunkCount: Int) async throws {
        let chunkNames = (0..<chunkCount).map {
            ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: $0)
        }
        await cache.evict(recordNames: chunkNames)
        try await store.delete(mediaRecordName: mediaRecordName, chunkCount: chunkCount)
    }
}
