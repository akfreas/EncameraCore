//
//  StreamingChunkSource.swift
//  EncameraCore
//
//  The chunk provider that sits between the ENC3 reader and CloudKit: an
//  in-memory chunk cache, a bounded read-ahead window, and the telemetry that
//  lets a test prove a seek fetched only what it needed.
//
//  Concurrency is deliberately small. CloudKit rate-limits aggressively — and it
//  surfaces as `serviceUnavailable` rather than the documented
//  `requestRateLimited`, with penalties that can last hours — so the read-ahead
//  window is 3 by default and never grows on its own. The gain from chunking is
//  first-byte latency, not saturating the link with parallel fetches.
//

import Foundation

// MARK: - Telemetry

/// What a streaming session actually did. Exists because the product claims here
/// ("playback starts before the file is downloaded", "a seek costs one chunk")
/// are invisible in the UI — the only honest way to assert them is to count the
/// bytes that crossed the network.
public struct StreamingTelemetry: Sendable, Equatable {
    public var chunksFetched: Int = 0
    public var chunksServedFromCache: Int = 0
    public var bytesFetched: Int = 0
    /// Distinct chunk indices fetched, in the order first requested.
    public var fetchOrder: [Int] = []
    /// Milliseconds from session start to the first chunk being ready.
    public var timeToFirstChunkMs: Int?
    /// Chunk indices whose fetch ran past the deadline, one entry per expiry. A
    /// chunk that expired twice before succeeding appears twice.
    public var deadlineExpiries: [Int] = []

    public init() {}

    /// Compact, locale-independent marker text for UI tests. The device rig runs a
    /// German handset where `0.5.formatted()` renders `0,5`, so no formatted number
    /// may ever appear in an assertion — every field here is a plain integer.
    public var markerText: String {
        "chunks=\(chunksFetched) cached=\(chunksServedFromCache) bytes=\(bytesFetched) "
        + "ttfc=\(timeToFirstChunkMs.map(String.init) ?? "-") order=\(fetchOrder.map(String.init).joined(separator: ","))"
        + " deadlines=\(deadlineExpiries.count)"
    }
}

/// Failures the chunk source raises itself, as opposed to passing through from
/// the store.
public enum StreamingChunkSourceError: Error, Equatable {
    /// Every attempt to fetch the chunk ran past the deadline.
    case fetchDeadlineExceeded(index: Int, attempts: Int)
}

// MARK: - Chunk source

/// A `SeekableChunkProviding` backed by a `ChunkedBlobStoring`, with an LRU cache
/// and a read-ahead window.
public actor StreamingChunkSource: SeekableChunkProviding, DebugPrintable {

    private let store: ChunkedBlobStoring
    private let mediaRecordName: String
    private let geometry: SeekableChunkGeometry
    /// Chunks fetched speculatively after each one served, never awaited.
    public nonisolated let readAhead: Int
    /// Budgeted in BYTES, not chunks.
    ///
    /// An earlier version capped the cache at 8 chunks, which is 32 MB at the 4 MiB
    /// production chunk but only 2 MB at the 256 KB probe chunk — so a 13-chunk
    /// probe blob thrashed and re-fetched chunks it had already paid for, nearly
    /// doubling measured network cost. A byte budget is correct at every chunk size.
    private let maxCachedBytes: Int
    private let fetchDeadline: Duration
    private let maxFetchAttempts: Int

    /// How long one attempt to fetch a chunk may run before it is abandoned and
    /// retried.
    ///
    /// Nothing below this layer times a chunk out: a CloudKit asset transfer whose
    /// connection has died sits for the URL loader's resource timeout (minutes),
    /// and every later request for that chunk rejoins the same stuck task. The
    /// deadline has to clear a legitimately slow fetch, though — a cold 4 MiB
    /// chunk has been observed taking 84 s on device — so it is generous, and
    /// cutting a slow fetch off costs a full re-download rather than a wait.
    public static let defaultFetchDeadline: Duration = .seconds(120)
    /// Total attempts per chunk before the failure reaches the caller.
    public static let defaultFetchAttempts = 3

    private var cache: [Int: Data] = [:]
    private var lru: [Int] = []
    private var cachedBytes = 0
    /// In-flight fetches, so two overlapping range requests for the same chunk share
    /// one network round trip instead of racing.
    private var inFlight: [Int: Task<Data, Error>] = [:]

    private var telemetry = StreamingTelemetry()
    private let startedAt = Date()

    public init(store: ChunkedBlobStoring,
                mediaRecordName: String,
                geometry: SeekableChunkGeometry,
                readAhead: Int = 3,
                maxCachedBytes: Int = 64 * 1024 * 1024,
                fetchDeadline: Duration = StreamingChunkSource.defaultFetchDeadline,
                maxFetchAttempts: Int = StreamingChunkSource.defaultFetchAttempts) {
        self.store = store
        self.mediaRecordName = mediaRecordName
        self.geometry = geometry
        self.readAhead = max(0, readAhead)
        self.maxCachedBytes = max(1, maxCachedBytes)
        self.fetchDeadline = fetchDeadline
        self.maxFetchAttempts = max(1, maxFetchAttempts)
    }

    public func currentTelemetry() -> StreamingTelemetry { telemetry }

    public func resetTelemetry() {
        telemetry = StreamingTelemetry()
    }

    // MARK: SeekableChunkProviding

    public func ciphertextChunk(at index: Int) async throws -> Data {
        let data = try await chunk(at: index)
        // Read-ahead is fire-and-forget and never awaited: the caller's byte range is
        // already satisfied, and blocking it on speculative work would trade the
        // latency win away.
        scheduleReadAhead(after: index)
        return data
    }

    // MARK: Internals

    private func chunk(at index: Int) async throws -> Data {
        if let cached = cache[index] {
            telemetry.chunksServedFromCache += 1
            touch(index)
            return cached
        }
        return try await fetchTask(for: index).value
    }

    /// The single place a chunk is pulled from the store.
    ///
    /// The task stored in `inFlight` supervises up to `maxFetchAttempts` store
    /// fetches, each run as its own task under the deadline. Everyone waiting on
    /// the chunk awaits the supervisor, never an attempt, so an attempt that is
    /// abandoned and retried is invisible to them: they receive the bytes the retry
    /// produces, not the cancellation of the attempt that hung.
    ///
    /// Recording happens inside the task body, immediately after the store returns
    /// and before the value is handed to anyone. That makes it exactly-once per
    /// network fetch: an earlier version recorded in both the direct path and the
    /// read-ahead completion, which let `chunksFetched` exceed the blob's chunk
    /// count and would have quietly inflated any byte-cost assertion.
    private func fetchTask(for index: Int) -> Task<Data, Error> {
        if let existing = inFlight[index] { return existing }
        let task = Task { [weak self, store, mediaRecordName, fetchDeadline, maxFetchAttempts] () -> Data in
            for attempt in 1...maxFetchAttempts {
                let startedAt = Date()
                if attempt > 1 {
                    await self?.printDebug("fetchChunk retry record=\(mediaRecordName) index=\(index) attempt=\(attempt)")
                }
                let fetch = Task { try await store.fetchChunk(mediaRecordName: mediaRecordName, index: index) }
                guard let outcome = await Self.outcome(of: fetch, within: fetchDeadline) else {
                    fetch.cancel()
                    await self?.printDebug("fetchChunk DEADLINE record=\(mediaRecordName) index=\(index) attempt=\(attempt) "
                                           + "after=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
                    await self?.recordDeadlineExpiry(index: index)
                    continue
                }
                switch outcome {
                case .success(let data):
                    await self?.printDebug("fetchChunk ok record=\(mediaRecordName) index=\(index) bytes=\(data.count) "
                                           + "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                    await self?.completeFetch(index: index, data: data)
                    return data
                case .failure(let error):
                    // The entry MUST go on failure too. `inFlight` is handed to every
                    // later request for the same chunk, so a failed task left behind is
                    // rethrown to each of them for the life of the session: one
                    // transient timeout would fail that chunk permanently, with the
                    // player parked and no further network traffic to show why.
                    await self?.printDebug("fetchChunk FAILED record=\(mediaRecordName) index=\(index) "
                                           + "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) raw=\(error)")
                    await self?.clearInFlight(index: index)
                    throw error
                }
            }
            await self?.clearInFlight(index: index)
            throw StreamingChunkSourceError.fetchDeadlineExceeded(index: index, attempts: maxFetchAttempts)
        }
        printDebug("fetchChunk start record=\(mediaRecordName) index=\(index)")
        inFlight[index] = task
        return task
    }

    /// The attempt's result, or `nil` once `deadline` passes without one.
    ///
    /// Neither structured tool fits a fetch that may never return: awaiting a
    /// task's `value` does not respond to cancellation, and a task group waits for
    /// every child before it returns. So the continuation is resumed exactly once
    /// by whichever of the attempt and the deadline finishes first, and a stuck
    /// attempt is left behind rather than waited on.
    private static func outcome(of attempt: Task<Data, Error>, within deadline: Duration) async -> Result<Data, Error>? {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            let timer = Task {
                do { try await Task.sleep(for: deadline) } catch { return }
                if once.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let result = await attempt.result
                timer.cancel()
                if once.claim() { continuation.resume(returning: result) }
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                if claimed { return false }
                claimed = true
                return true
            }
        }
    }

    private func completeFetch(index: Int, data: Data) {
        inFlight[index] = nil
        guard cache[index] == nil else { return }
        record(index: index, bytes: data.count)
        store(index: index, data: data)
    }

    private func recordDeadlineExpiry(index: Int) {
        telemetry.deadlineExpiries.append(index)
    }

    private func record(index: Int, bytes: Int) {
        telemetry.chunksFetched += 1
        telemetry.bytesFetched += bytes
        if !telemetry.fetchOrder.contains(index) {
            telemetry.fetchOrder.append(index)
        }
        if telemetry.timeToFirstChunkMs == nil {
            telemetry.timeToFirstChunkMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        }
    }

    private func store(index: Int, data: Data) {
        cache[index] = data
        cachedBytes += data.count
        touch(index)
        while cachedBytes > maxCachedBytes, lru.count > 1, let evict = lru.first {
            lru.removeFirst()
            cachedBytes -= cache[evict]?.count ?? 0
            cache[evict] = nil
        }
    }

    private func touch(_ index: Int) {
        lru.removeAll { $0 == index }
        lru.append(index)
    }

    private func scheduleReadAhead(after index: Int) {
        guard readAhead > 0 else { return }
        for next in (index + 1)...(index + readAhead) where next < geometry.chunkCount {
            guard cache[next] == nil, inFlight[next] == nil else { continue }
            let task = fetchTask(for: next)
            // Detached from the caller: a read-ahead failure must not surface as the
            // caller's error, and a cancelled read-ahead must not leave a stale
            // in-flight entry that blocks a later real request for the same chunk.
            Task { [weak self] in
                if (try? await task.value) == nil { await self?.clearInFlight(index: next) }
            }
        }
    }

    private func clearInFlight(index: Int) {
        inFlight[index] = nil
    }
}

// MARK: - Session

/// Everything needed to stream one chunked blob: the header, the key, a chunk
/// source, and the reader that turns byte ranges into plaintext.
public struct ChunkedStreamSession: Sendable {
    public let mediaRecordName: String
    public let header: SeekableEncryptedHeader
    public let source: StreamingChunkSource
    public let reader: SeekableEncryptedReader

    public var geometry: SeekableChunkGeometry { header.geometry }
    public var plaintextLength: Int { header.plaintextLength }

    /// Builds the chunk source and the reader for a blob whose header the caller
    /// already holds. The header travels on the commit record, so opening a session
    /// costs no extra round trip.
    public static func open(store: ChunkedBlobStoring,
                            mediaRecordName: String,
                            header: SeekableEncryptedHeader,
                            keyBytes: [UInt8],
                            readAhead: Int = 3,
                            fetchDeadline: Duration = StreamingChunkSource.defaultFetchDeadline) -> ChunkedStreamSession {
        let source = StreamingChunkSource(store: store,
                                          mediaRecordName: mediaRecordName,
                                          geometry: header.geometry,
                                          readAhead: readAhead,
                                          fetchDeadline: fetchDeadline)
        let reader = SeekableEncryptedReader(keyBytes: keyBytes, header: header, provider: source)
        return ChunkedStreamSession(mediaRecordName: mediaRecordName,
                                    header: header,
                                    source: source,
                                    reader: reader)
    }

    public func telemetry() async -> StreamingTelemetry {
        await source.currentTelemetry()
    }
}
