//
//  StreamingChunkSourceTests.swift
//  EncameraCoreTests
//
//  The transport-level claims: a byte range costs only the chunks it overlaps, a
//  repeat read costs nothing, overlapping reads share one fetch, and read-ahead
//  stays inside its window.
//

import XCTest
@testable import EncameraCore

final class StreamingChunkSourceTests: XCTestCase {

    private let key = [UInt8](repeating: 0x7A, count: 32)
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fixture(bytes count: Int) -> Data {
        var data = Data(capacity: count)
        var state: UInt64 = 0x243F6A8885A308D3
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    /// Builds an ENC3 blob of `bytes` and loads it into an in-memory store.
    private func seed(bytes: Int, chunkSize: Int) async throws -> (store: InMemoryChunkedBlobStore,
                                                                   plaintext: Data,
                                                                   header: SeekableEncryptedHeader) {
        let plaintext = fixture(bytes: bytes)
        let source = tempDir.appendingPathComponent("src.bin")
        try plaintext.write(to: source)
        let enc3 = tempDir.appendingPathComponent("blob.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: key, chunkSize: chunkSize)
            .encrypt(source: source, destination: enc3)

        let store = InMemoryChunkedBlobStore()
        try await store.uploadChunks(enc3FileURL: enc3, mediaRecordName: "media-1", progress: { _ in })
        return (store, plaintext, header)
    }

    /// A store that fails the first `failures` fetches of `failingIndex`, then
    /// behaves. Models a transient CloudKit timeout on one chunk.
    private actor FlakyChunkStore: ChunkedBlobStoring {
        private let backing: InMemoryChunkedBlobStore
        private let failingIndex: Int
        private var remainingFailures: Int
        private(set) var attempts = 0

        init(backing: InMemoryChunkedBlobStore, failingIndex: Int, failures: Int) {
            self.backing = backing
            self.failingIndex = failingIndex
            self.remainingFailures = failures
        }

        struct Timeout: Error {}

        func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
            attempts += 1
            if index == failingIndex, remainingFailures > 0 {
                remainingFailures -= 1
                throw Timeout()
            }
            return try await backing.fetchChunk(mediaRecordName: mediaRecordName, index: index)
        }

        @discardableResult
        func uploadChunks(enc3FileURL: URL, mediaRecordName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
            try await backing.uploadChunks(enc3FileURL: enc3FileURL, mediaRecordName: mediaRecordName, progress: progress)
        }

        func delete(mediaRecordName: String, chunkCount: Int) async throws {
            try await backing.delete(mediaRecordName: mediaRecordName, chunkCount: chunkCount)
        }
    }

    /// One failed fetch must not fail that chunk forever.
    ///
    /// The in-flight map is shared with every later request for the same chunk, so
    /// a failed task left in it is rethrown to all of them: playback stalls with
    /// the player parked and no further network traffic, which is exactly how this
    /// presented on device — a chunk timed out once and the video never recovered.
    func testAFailedChunkFetchIsRetriedRatherThanFailingForever() async throws {
        let (backing, plaintext, _) = try await seed(bytes: 50_000, chunkSize: 4_096)
        let flaky = FlakyChunkStore(backing: backing, failingIndex: 2, failures: 1)
        let source = StreamingChunkSource(store: flaky,
                                          mediaRecordName: "media-1",
                                          geometry: SeekableChunkGeometry(chunkSize: 4_096,
                                                                          plaintextLength: plaintext.count,
                                                                          headerLength: 0),
                                          readAhead: 0)

        do {
            _ = try await source.ciphertextChunk(at: 2)
            XCTFail("the fixture must fail the first attempt, or this proves nothing")
        } catch {
            // Expected: the transient failure.
        }

        let recovered = try await source.ciphertextChunk(at: 2)
        XCTAssertFalse(recovered.isEmpty,
                       "the second request reused the failed task instead of refetching, so this chunk "
                       + "can never be read again for the life of the session")
    }

    // MARK: - Hung fetches

    /// A store whose `fetchChunk` for `hangingIndex` never returns on its first
    /// `hangs` attempts and serves normally after that. Models a CloudKit asset
    /// transfer whose connection has died: no error, no bytes, no end — and, like
    /// that transfer, it does not notice being cancelled.
    private actor HangingChunkStore: ChunkedBlobStoring {
        private let backing: InMemoryChunkedBlobStore
        private let hangingIndex: Int
        private var remainingHangs: Int
        private var attemptsByIndex: [Int: Int] = [:]

        init(backing: InMemoryChunkedBlobStore, hangingIndex: Int, hangs: Int) {
            self.backing = backing
            self.hangingIndex = hangingIndex
            self.remainingHangs = hangs
        }

        func attempts(for index: Int) -> Int { attemptsByIndex[index, default: 0] }

        func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
            attemptsByIndex[index, default: 0] += 1
            if index == hangingIndex, remainingHangs > 0 {
                remainingHangs -= 1
                // Unsafe on purpose: never resuming is the behaviour under test,
                // and the checked variant reports it as a leak.
                try await withUnsafeThrowingContinuation { (_: UnsafeContinuation<Void, Error>) in }
            }
            return try await backing.fetchChunk(mediaRecordName: mediaRecordName, index: index)
        }

        @discardableResult
        func uploadChunks(enc3FileURL: URL, mediaRecordName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
            try await backing.uploadChunks(enc3FileURL: enc3FileURL, mediaRecordName: mediaRecordName, progress: progress)
        }

        func delete(mediaRecordName: String, chunkCount: Int) async throws {
            try await backing.delete(mediaRecordName: mediaRecordName, chunkCount: chunkCount)
        }
    }

    private struct DidNotComplete: Error {}

    private final class OutcomeBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        func set(_ result: Result<T, Error>) { lock.withLock { value = result } }
        func get() -> Result<T, Error>? { lock.withLock { value } }
    }

    /// Runs `work` and fails the test, rather than hanging the runner, when it has
    /// not finished within `seconds`. A task group would wait on the stuck child,
    /// so the bound is an expectation instead.
    private func completes<T: Sendable>(within seconds: TimeInterval,
                                        _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome = OutcomeBox<T>()
        let finished = expectation(description: "completes within \(seconds)s")
        let task = Task {
            do { outcome.set(.success(try await work())) } catch { outcome.set(.failure(error)) }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: seconds)
        guard let result = outcome.get() else {
            task.cancel()
            throw DidNotComplete()
        }
        return try result.get()
    }

    private func geometry(chunkSize: Int, plaintext: Data) -> SeekableChunkGeometry {
        SeekableChunkGeometry(chunkSize: chunkSize, plaintextLength: plaintext.count, headerLength: 0)
    }

    /// A fetch that never returns must not park the session forever.
    ///
    /// The throwing case above reaches `clearInFlight`; a hung fetch never does. On
    /// device this presented as a handful of `fetchChunk start` lines, then
    /// silence, with the player waiting at time 0 until the URL loader's own
    /// timeout fired minutes later.
    func testAHungChunkFetchIsRetriedAfterTheDeadline() async throws {
        let (backing, plaintext, _) = try await seed(bytes: 50_000, chunkSize: 4_096)
        let hanging = HangingChunkStore(backing: backing, hangingIndex: 2, hangs: 1)
        let source = StreamingChunkSource(store: hanging,
                                          mediaRecordName: "media-1",
                                          geometry: geometry(chunkSize: 4_096, plaintext: plaintext),
                                          readAhead: 0,
                                          fetchDeadline: .milliseconds(100))

        let got = try await completes(within: 5) { try await source.ciphertextChunk(at: 2) }

        let expected = try await backing.fetchChunk(mediaRecordName: "media-1", index: 2)
        XCTAssertEqual(got, expected)
        let attempts = await hanging.attempts(for: 2)
        XCTAssertEqual(attempts, 2, "the hung attempt must be abandoned and the chunk fetched again")
        let telemetry = await source.currentTelemetry()
        XCTAssertEqual(telemetry.deadlineExpiries, [2])
        XCTAssertEqual(telemetry.chunksFetched, 1, "the abandoned attempt moved no bytes and must not be counted")
    }

    func testAPermanentlyHungChunkFetchFailsAfterBoundedRetries() async throws {
        let (backing, plaintext, _) = try await seed(bytes: 50_000, chunkSize: 4_096)
        let hanging = HangingChunkStore(backing: backing, hangingIndex: 2, hangs: .max)
        let source = StreamingChunkSource(store: hanging,
                                          mediaRecordName: "media-1",
                                          geometry: geometry(chunkSize: 4_096, plaintext: plaintext),
                                          readAhead: 0,
                                          fetchDeadline: .milliseconds(100),
                                          maxFetchAttempts: 3)

        await XCTAssertThrowsErrorAsync(try await completes(within: 5) { try await source.ciphertextChunk(at: 2) }) { error in
            XCTAssertEqual(error as? StreamingChunkSourceError, .fetchDeadlineExceeded(index: 2, attempts: 3))
        }
        let attemptsAfterFirstRequest = await hanging.attempts(for: 2)
        XCTAssertEqual(attemptsAfterFirstRequest, 3)
        let telemetry = await source.currentTelemetry()
        XCTAssertEqual(telemetry.deadlineExpiries, [2, 2, 2])

        // The failed request must not be handed to the next one.
        await XCTAssertThrowsErrorAsync(try await completes(within: 5) { try await source.ciphertextChunk(at: 2) }) { error in
            XCTAssertEqual(error as? StreamingChunkSourceError, .fetchDeadlineExceeded(index: 2, attempts: 3))
        }
        let attemptsAfterSecondRequest = await hanging.attempts(for: 2)
        XCTAssertEqual(attemptsAfterSecondRequest, 6, "a later request must start a fresh fetch, not rejoin the dead one")
    }

    /// A demand read that rejoins a read-ahead already in flight must get the
    /// bytes the retry produces — never a cancellation error from the abandoned
    /// attempt, and never a wait on it.
    func testAWaiterThatRejoinedAHungFetchReceivesTheRetriedBytes() async throws {
        let (backing, plaintext, _) = try await seed(bytes: 50_000, chunkSize: 4_096)
        let hanging = HangingChunkStore(backing: backing, hangingIndex: 1, hangs: 1)
        let source = StreamingChunkSource(store: hanging,
                                          mediaRecordName: "media-1",
                                          geometry: geometry(chunkSize: 4_096, plaintext: plaintext),
                                          readAhead: 1,
                                          fetchDeadline: .milliseconds(300))

        // Chunk 0 arms read-ahead of chunk 1, whose first attempt hangs.
        _ = try await source.ciphertextChunk(at: 0)
        try await Task.sleep(for: .milliseconds(50))
        let readAheadAttempts = await hanging.attempts(for: 1)
        XCTAssertEqual(readAheadAttempts, 1,
                       "the fixture must have chunk 1 in flight as read-ahead before the demand read, "
                       + "or this proves nothing about rejoining")

        let got = try await completes(within: 5) { try await source.ciphertextChunk(at: 1) }

        let expected = try await backing.fetchChunk(mediaRecordName: "media-1", index: 1)
        XCTAssertEqual(got, expected)
        let attempts = await hanging.attempts(for: 1)
        XCTAssertEqual(attempts, 2)
        let telemetry = await source.currentTelemetry()
        XCTAssertEqual(telemetry.deadlineExpiries, [1])
    }

    /// The deadline is for fetches that have stopped, not for fetches that are slow.
    func testASlowButSuccessfulFetchIsNotCutOffBelowTheDeadline() async throws {
        let (store, plaintext, _) = try await seed(bytes: 50_000, chunkSize: 4_096)
        let expected = try await store.fetchChunk(mediaRecordName: "media-1", index: 2)
        await store.resetLog()
        await store.setChunkLatency(.milliseconds(150))
        let source = StreamingChunkSource(store: store,
                                          mediaRecordName: "media-1",
                                          geometry: geometry(chunkSize: 4_096, plaintext: plaintext),
                                          readAhead: 0,
                                          fetchDeadline: .milliseconds(1_000))

        let got = try await completes(within: 5) { try await source.ciphertextChunk(at: 2) }

        XCTAssertEqual(got, expected)
        let fetched = await store.fetchedIndices
        XCTAssertEqual(fetched, [2], "a fetch that finishes inside the deadline must run exactly once")
        let telemetry = await source.currentTelemetry()
        XCTAssertEqual(telemetry.deadlineExpiries, [])
    }

    // MARK: - Round trip through the transport

    func testStreamedRangeMatchesOriginal() async throws {
        let (store, plaintext, header) = try await seed(bytes: 50_000, chunkSize: 4_096)
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)
        XCTAssertEqual(session.plaintextLength, 50_000)
        let got = try await session.reader.plaintext(range: 10_000..<20_000)
        XCTAssertEqual(got, plaintext.subdata(in: 10_000..<20_000))
    }

    func testWholeBlobStreamsBackByteIdentical() async throws {
        let (store, plaintext, header) = try await seed(bytes: 30_000, chunkSize: 4_096)
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)
        let got = try await session.reader.plaintext(range: 0..<30_000)
        XCTAssertEqual(got, plaintext)
    }

    // MARK: - The product claim: a seek is cheap

    func testSeekIntoTheMiddleDoesNotFetchTheWholeBlob() async throws {
        let (store, plaintext, header) = try await seed(bytes: 400_000, chunkSize: 10_000)
        XCTAssertEqual(header.chunkCount, 40)

        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)
        let got = try await session.reader.plaintext(range: 200_000..<200_500)
        XCTAssertEqual(got, plaintext.subdata(in: 200_000..<200_500))

        let telemetry = await session.telemetry()
        XCTAssertEqual(telemetry.chunksFetched, 1, "one chunk, not forty")
        XCTAssertEqual(telemetry.fetchOrder, [20])
        XCTAssertLessThan(telemetry.bytesFetched, 20_000)
    }

    func testRepeatedReadOfTheSameRegionHitsTheCache() async throws {
        let (store, _, header) = try await seed(bytes: 100_000, chunkSize: 10_000)
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)
        _ = try await session.reader.plaintext(range: 0..<100)
        _ = try await session.reader.plaintext(range: 200..<300)

        let afterReads = await session.telemetry()
        XCTAssertEqual(afterReads.chunksFetched, 1)
        XCTAssertEqual(afterReads.chunksServedFromCache, 0,
                       "the reader's plaintext cache answers the repeat above this source")

        // The ciphertext cache still serves a repeat that does reach the source —
        // a second reader over the same session, or a chunk the reader evicted.
        _ = try await session.source.ciphertextChunk(at: 0)
        let afterDirectRead = await session.telemetry()
        XCTAssertEqual(afterDirectRead.chunksFetched, 1)
        XCTAssertEqual(afterDirectRead.chunksServedFromCache, 1)
    }

    func testConcurrentReadsOfOneChunkShareASingleFetch() async throws {
        let (store, _, header) = try await seed(bytes: 100_000, chunkSize: 10_000)
        await store.setChunkLatency(.milliseconds(50))
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)

        async let a = session.reader.plaintext(range: 0..<100)
        async let b = session.reader.plaintext(range: 500..<600)
        _ = try await (a, b)

        let storeFetches = await store.fetchedIndices
        XCTAssertEqual(storeFetches, [0], "two overlapping reads must not race the network twice")
    }

    // MARK: - Read-ahead

    func testReadAheadStaysInsideItsWindow() async throws {
        let (store, _, header) = try await seed(bytes: 400_000, chunkSize: 10_000)
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 3)
        _ = try await session.reader.plaintext(range: 0..<100)

        // Read-ahead is fire-and-forget, so give it a moment to land before counting.
        try await Task.sleep(for: .milliseconds(300))
        let fetched = Set(await store.fetchedIndices)
        XCTAssertTrue(fetched.isSubset(of: [0, 1, 2, 3]),
                      "read-ahead must not run away past its window; got \(fetched.sorted())")
        XCTAssertTrue(fetched.contains(0))
    }

    func testReadAheadDoesNotRunPastTheEndOfTheBlob() async throws {
        let (store, _, header) = try await seed(bytes: 25_000, chunkSize: 10_000)
        XCTAssertEqual(header.chunkCount, 3)
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 5)
        _ = try await session.reader.plaintext(range: 20_000..<25_000)
        try await Task.sleep(for: .milliseconds(300))

        let fetched = Set(await store.fetchedIndices)
        XCTAssertTrue(fetched.isSubset(of: [0, 1, 2]), "no chunk index may exceed chunkCount - 1")
    }

    // MARK: - Failure surfaces

    func testWrongKeyFailsAtTheChunkNotAtTheHeader() async throws {
        let (store, _, header) = try await seed(bytes: 30_000, chunkSize: 10_000)
        // The header is plaintext framing, so opening a session with the wrong key
        // must still succeed — the failure has to land on the first chunk, where it
        // is attributable.
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "media-1",
                                                header: header,
                                                keyBytes: [UInt8](repeating: 0x01, count: 32),
                                                readAhead: 0)
        XCTAssertEqual(session.plaintextLength, 30_000)
        await XCTAssertThrowsErrorAsync(try await session.reader.plaintextChunk(at: 0)) { error in
            XCTAssertEqual(error as? SeekableFormatError, .chunkAuthenticationFailed(index: 0))
        }
    }

    // MARK: - Naming

    func testChunkRecordNamesAreDeterministic() {
        XCTAssertEqual(ChunkedBlobSchema.chunkRecordName(mediaRecordName: "abc", index: 7), "abc#c7")
    }

    func testStreamURLRoundTripsTheRecordName() throws {
        let url = try XCTUnwrap(EncryptedStreamScheme.url(mediaRecordName: "media-1"))
        XCTAssertEqual(url.scheme, "encamera-enc")
        XCTAssertEqual(EncryptedStreamScheme.mediaRecordName(from: url), "media-1")
        // An http URL must not resolve — the delegate is never consulted for one, so
        // treating it as ours would silently produce a video that never loads.
        let http = try XCTUnwrap(URL(string: "https://example.com/media-1"))
        XCTAssertNil(EncryptedStreamScheme.mediaRecordName(from: http))
    }

    func testTelemetryMarkerTextIsLocaleIndependent() {
        var telemetry = StreamingTelemetry()
        telemetry.chunksFetched = 3
        telemetry.bytesFetched = 12_582_912
        telemetry.timeToFirstChunkMs = 145
        telemetry.fetchOrder = [0, 1, 2]
        let text = telemetry.markerText
        // The rig runs German handsets, where a formatted 12582912 renders as
        // "12.582.912" and would break a string assertion. Every numeric field must
        // be a bare integer.
        XCTAssertTrue(text.contains("bytes=12582912"), text)
        XCTAssertTrue(text.contains("chunks=3"), text)
        XCTAssertTrue(text.contains("ttfc=145"), text)
        XCTAssertTrue(text.contains("order=0,1,2"), text)
        XCTAssertFalse(text.contains("12.582.912"), text)
    }
}
