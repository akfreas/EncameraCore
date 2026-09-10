//
//  EncryptedStreamResourceLoaderTests.swift
//  EncameraCoreTests
//
//  The resource loader is the component most likely to hold a subtle bug and the
//  most expensive to iterate on: until now it was only exercised by launching the
//  app (a UI test) or the rig. Neither is necessary for the parts that can be
//  wrong.
//
//  Two layers here:
//
//  1. `resolvedRange` — the byte arithmetic, tested exhaustively. This cannot be
//     covered any other way: `AVAssetResourceLoadingDataRequest` has no public
//     initializer, so the only alternative is driving a real AVPlayer and hoping
//     it happens to issue the edge-case requests.
//  2. `responseSlices` — the slices the player would actually receive, asserted to
//     reassemble into exactly the right plaintext and to touch only the chunks the
//     range overlaps.
//
//  What still needs AVFoundation (and so lives in `ChunkedStreamingLocalUITests`)
//  is whether AVPlayer *accepts* what we hand it — the content-information
//  contract and the unanswered 2-byte data request.
//

import XCTest
import AVFoundation
import UIKit
@testable import EncameraCore

final class EncryptedStreamResourceLoaderTests: XCTestCase {

    private let key = [UInt8](repeating: 0x11, count: 32)
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fixture(bytes count: Int) -> Data {
        var data = Data(capacity: count)
        var state: UInt64 = 0xA5A5A5A5DEADC0DE
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    private func makeSession(bytes: Int, chunkSize: Int)
        async throws -> (session: ChunkedStreamSession, store: InMemoryChunkedBlobStore, plaintext: Data) {
        let plaintext = fixture(bytes: bytes)
        let source = tempDir.appendingPathComponent("src.bin")
        try plaintext.write(to: source)
        let enc3 = tempDir.appendingPathComponent("blob.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: chunkSize)
            .encrypt(source: source, destination: enc3)

        let store = InMemoryChunkedBlobStore()
        let header = try await store.uploadChunks(enc3FileURL: enc3, mediaRecordName: "m", progress: { _ in })
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "m",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)
        return (session, store, plaintext)
    }

    // MARK: - resolvedRange

    func testResolvedRangeForAnOrdinaryRequest() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 100, requestedLength: 50, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertEqual(range, 100..<150)
    }

    func testResolvedRangeClampsARequestStraddlingTheEnd() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 900, requestedLength: 500, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertEqual(range, 900..<1_000, "must clamp rather than promise bytes that do not exist")
    }

    func testResolvedRangeForRequestsAllDataToEndOfResource() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 250, requestedLength: 2, requestsAllToEnd: true, plaintextLength: 1_000)
        XCTAssertEqual(range, 250..<1_000, "the requested length is meaningless when all-to-end is set")
    }

    func testResolvedRangeIsEmptyEntirelyPastTheEnd() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 1_000, requestedLength: 10, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertTrue(range.isEmpty, "an offset at or past EOF must yield nothing, not a negative length")
    }

    func testResolvedRangeIsEmptyForZeroLength() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 10, requestedLength: 0, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertTrue(range.isEmpty)
    }

    func testResolvedRangeHandlesAnEmptyResource() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 0, requestedLength: 10, requestsAllToEnd: true, plaintextLength: 0)
        XCTAssertTrue(range.isEmpty)
    }

    func testResolvedRangeClampsANegativeOffset() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: -5, requestedLength: 20, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertEqual(range, 0..<15)
    }

    func testResolvedRangeCoversTheWholeResource() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 0, requestedLength: 0, requestsAllToEnd: true, plaintextLength: 4_096)
        XCTAssertEqual(range, 0..<4_096)
    }

    // MARK: - responseSlices

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> [Data] {
        var out: [Data] = []
        for try await slice in stream { out.append(slice) }
        return out
    }

    func testSlicesReassembleIntoExactlyTheRequestedBytes() async throws {
        let (session, _, plaintext) = try await makeSession(bytes: 10_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)

        for range in [0..<1, 0..<1_000, 999..<1_001, 2_500..<7_500, 9_000..<10_000, 0..<10_000] {
            let slices = try await collect(loader.responseSlices(for: range))
            let joined = slices.reduce(into: Data()) { $0.append($1) }
            XCTAssertEqual(joined, plaintext.subdata(in: range), "range \(range) reassembled wrong")
        }
    }

    /// Incremental delivery is what lets AVPlayer start on a partial buffer instead
    /// of waiting for the whole request, so a multi-chunk range must arrive as
    /// several slices rather than one blob at the end.
    func testAMultiChunkRangeArrivesAsSeveralSlices() async throws {
        let (session, _, _) = try await makeSession(bytes: 10_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)

        let slices = try await collect(loader.responseSlices(for: 0..<3_500))
        XCTAssertEqual(slices.count, 4, "one slice per overlapped chunk")
        XCTAssertEqual(slices.map(\.count), [1_000, 1_000, 1_000, 500])
    }

    func testServingARangeTouchesOnlyTheChunksItOverlaps() async throws {
        let (session, store, _) = try await makeSession(bytes: 100_000, chunkSize: 10_000)
        let loader = EncryptedStreamResourceLoader(session: session)

        _ = try await collect(loader.responseSlices(for: 55_000..<56_000))
        let fetched = await store.fetchedIndices
        XCTAssertEqual(fetched, [5], "a 1 KB range must not pull the file")
    }

    func testAnEmptyRangeYieldsNothingAndFetchesNothing() async throws {
        let (session, store, _) = try await makeSession(bytes: 5_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)

        let slices = try await collect(loader.responseSlices(for: 0..<0))
        XCTAssertTrue(slices.isEmpty)
        let fetched = await store.fetchedIndices
        XCTAssertTrue(fetched.isEmpty)
    }

    /// A tampered or undecryptable chunk must surface as a thrown error so the
    /// loader can fail the request, rather than silently yielding short data — which
    /// AVPlayer would render as corruption.
    func testAnUndecryptableChunkThrowsRatherThanYieldingShortData() async throws {
        let (session, _, _) = try await makeSession(bytes: 5_000, chunkSize: 1_000)
        let wrongKeyReader = SeekableEncryptedReader(keyBytes: [UInt8](repeating: 0x99, count: 32),
                                                     header: session.header,
                                                     provider: session.source)
        let brokenSession = ChunkedStreamSession(mediaRecordName: session.mediaRecordName,
                                                 header: session.header,
                                                 source: session.source,
                                                 reader: wrongKeyReader)
        let loader = EncryptedStreamResourceLoader(session: brokenSession)

        await XCTAssertThrowsErrorAsync(try await collect(loader.responseSlices(for: 0..<2_000))) { error in
            XCTAssertEqual(error as? SeekableFormatError, .chunkAuthenticationFailed(index: 0))
        }
    }

    /// AVFoundation's range requests are far smaller than a chunk, so several
    /// requests land inside one. `PoisonAfterFirstServeProvider` corrupts the second
    /// serve of an index, so a loader that re-decrypted per request would throw here;
    /// the slices are also asserted to be exactly the requested plaintext.
    func testOverlappingRequestsInsideOneChunkDecryptItOnce() async throws {
        let (session, _, plaintext) = try await makeSession(bytes: 10_000, chunkSize: 4_000)
        let spy = PoisonAfterFirstServeProvider(wrapped: session.source)
        let cachingSession = ChunkedStreamSession(
            mediaRecordName: session.mediaRecordName,
            header: session.header,
            source: session.source,
            reader: SeekableEncryptedReader(keyBytes: key, header: session.header, provider: spy))
        let loader = EncryptedStreamResourceLoader(session: cachingSession)

        for range in [0..<500, 500..<1_500, 1_200..<4_000] {
            let slices = try await collect(loader.responseSlices(for: range))
            let joined = slices.reduce(into: Data()) { $0.append($1) }
            XCTAssertEqual(joined, plaintext.subdata(in: range), "range \(range) served wrong bytes")
        }
        let served = await spy.served
        XCTAssertEqual(served, [0], "three requests inside chunk 0 must cost one decrypt")
    }

    func testCancellingTheStreamStopsFetching() async throws {
        let (session, store, _) = try await makeSession(bytes: 100_000, chunkSize: 10_000)
        await store.setChunkLatency(.milliseconds(50))
        let loader = EncryptedStreamResourceLoader(session: session)

        let task = Task { try await collect(loader.responseSlices(for: 0..<100_000)) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = try? await task.value
        let afterCancel = await store.fetchedIndices.count

        try await Task.sleep(for: .milliseconds(300))
        let settled = await store.fetchedIndices.count
        XCTAssertLessThan(settled, 10, "cancellation must stop the remaining chunk fetches")
        XCTAssertLessThanOrEqual(settled - afterCancel, 1,
                                 "at most the in-flight chunk may land after cancellation")
    }

    // MARK: - Player item wiring

    @MainActor
    func testPlayerItemUsesTheCustomSchemeSoTheDelegateIsConsulted() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)
        let item = try XCTUnwrap(loader.makePlayerItem())
        let itemAsset = item.asset
        let asset = try XCTUnwrap(itemAsset as? AVURLAsset)

        // AVFoundation never consults a resource loader for http/https, so getting
        // this wrong produces a video that simply never loads, with no error.
        XCTAssertEqual(asset.url.scheme, EncryptedStreamScheme.scheme)
        XCTAssertEqual(EncryptedStreamScheme.mediaRecordName(from: asset.url), "m")
    }

    /// The item is asked to buffer about one chunk ahead, not the ~18 s the
    /// player settles on by itself over a delegate-fed asset.
    @MainActor
    func testStreamingPlaybackAppliesThePolicyBufferDurationToTheItem() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)

        let item = try XCTUnwrap(playback.makePlayerItem())

        XCTAssertEqual(item.preferredForwardBufferDuration,
                       StreamingPlaybackPolicy.cloudKit.preferredForwardBufferDuration)
        XCTAssertGreaterThan(StreamingPlaybackPolicy.cloudKit.preferredForwardBufferDuration, 0,
                             "0 hands the choice back to AVPlayer, which is the wait being tuned away")
    }

    /// The player must not wait to minimize stalls: over a resource loader that
    /// wait held the first frame for two minutes with the item already ready.
    @MainActor
    func testStreamingPlaybackMakesAPlayerThatDoesNotWaitToMinimizeStalls() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)

        let player = try XCTUnwrap(playback.makePlayer())

        XCTAssertFalse(player.automaticallyWaitsToMinimizeStalling)
        XCTAssertFalse(StreamingPlaybackPolicy.cloudKit.automaticallyWaitsToMinimizeStalling)
        let asset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url.scheme, EncryptedStreamScheme.scheme, "the player must play a loader-backed item")
        XCTAssertEqual(player.currentItem?.preferredForwardBufferDuration,
                       StreamingPlaybackPolicy.cloudKit.preferredForwardBufferDuration)
    }

    /// A store that delivers the first `promptChunks` chunks at once and every
    /// later one after `delay`, so a short clip starts quickly and then outruns
    /// its feed — the shape of a cold CloudKit stream, compressed into seconds.
    private actor ThrottledChunkStore: ChunkedBlobStoring {
        private let backing: InMemoryChunkedBlobStore
        private let promptChunks: Int
        private let delay: Duration

        init(backing: InMemoryChunkedBlobStore, promptChunks: Int, delay: Duration) {
            self.backing = backing
            self.promptChunks = promptChunks
            self.delay = delay
        }

        func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
            if index >= promptChunks { try await Task.sleep(for: delay) }
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

    /// With waiting-to-minimize-stalls off, a buffer that runs dry mid-playback
    /// leaves the player paused at rate 0 — AVFoundation does not restart it. The
    /// stall recovery must, or a cold video plays its first chunk and freezes.
    @MainActor
    func testAStreamedPlayerResumesAfterItStallsForData() async throws {
        let movie = tempDir.appendingPathComponent("stall.mov")
        try await Self.writeTinyMovie(to: movie, seconds: 4, fastStart: true)
        let enc3 = tempDir.appendingPathComponent("stall.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 16 * 1024)
            .encrypt(source: movie, destination: enc3)
        let backing = InMemoryChunkedBlobStore()
        let header = try await backing.uploadChunks(enc3FileURL: enc3, mediaRecordName: "stall", progress: { _ in })
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(400))
        let session = ChunkedStreamSession.open(store: store, mediaRecordName: "stall", header: header, keyBytes: key, readAhead: 0)
        XCTAssertGreaterThan(session.geometry.chunkCount, 12, "the clip must outrun a 400 ms-per-chunk feed")

        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let item = try XCTUnwrap(player.currentItem)
        player.play()

        let duration = try await item.asset.load(.duration)
        var sawPausedWithEmptyBuffer = false
        var reachedEnd = false
        for _ in 0..<600 {
            if item.status == .failed {
                XCTFail("player item failed: \(item.error.map { "\($0)" } ?? "unknown")")
                return
            }
            if player.timeControlStatus == .paused, item.isPlaybackBufferEmpty, item.status == .readyToPlay {
                sawPausedWithEmptyBuffer = true
            }
            if CMTimeGetSeconds(item.currentTime()) >= CMTimeGetSeconds(duration) - 0.5 {
                reachedEnd = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(sawPausedWithEmptyBuffer, "the feed never ran the player dry, so nothing was recovered from")
        XCTAssertTrue(reachedEnd, "the player stopped at \(CMTimeGetSeconds(item.currentTime()))s of "
                      + "\(CMTimeGetSeconds(duration))s — status=\(player.timeControlStatus.rawValue) "
                      + "rate=\(player.rate) bufferEmpty=\(item.isPlaybackBufferEmpty) "
                      + "keepUp=\(item.isPlaybackLikelyToKeepUp)")
        let supervisor = try XCTUnwrap(playback.supervisor, "makePlayer() must install the supervisor")
        XCTAssertGreaterThanOrEqual(supervisor.resumeCount, 1)
        XCTAssertEqual(supervisor.rebuildCount, 0, "a stall is not a failure")

        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// A short clip encrypted and uploaded to `store`, opened as a session with
    /// no read-ahead so the store sees exactly the chunks the player asks for.
    private func makeMovieSession(name: String,
                                  seconds: Int,
                                  store: ChunkedBlobStoring,
                                  backing: InMemoryChunkedBlobStore) async throws -> ChunkedStreamSession {
        let movie = tempDir.appendingPathComponent("\(name).mov")
        try await Self.writeTinyMovie(to: movie, seconds: seconds, fastStart: true)
        let enc3 = tempDir.appendingPathComponent("\(name).enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 16 * 1024)
            .encrypt(source: movie, destination: enc3)
        let header = try await backing.uploadChunks(enc3FileURL: enc3, mediaRecordName: name, progress: { _ in })
        return ChunkedStreamSession.open(store: store, mediaRecordName: name, header: header, keyBytes: key, readAhead: 0)
    }

    private func waitUntil(_ timeout: Duration = .seconds(15),
                           _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @MainActor
    private func describe(_ player: AVPlayer) -> String {
        let item = player.currentItem
        return "status=\(player.timeControlStatus.rawValue) rate=\(player.rate) "
            + "time=\(item.map { CMTimeGetSeconds($0.currentTime()) } ?? -1) "
            + "itemStatus=\(item?.status.rawValue ?? -1) "
            + "error=\(item?.error.map { "\($0)" } ?? "none") "
            + "bufferEmpty=\(item?.isPlaybackBufferEmpty ?? false) keepUp=\(item?.isPlaybackLikelyToKeepUp ?? false)"
    }

    /// The `AVPlayerViewController` that presents a streamed player must be its
    /// only owner — that is what makes dismissing it stop the audio. The
    /// supervisor watches the player; it must not keep it alive.
    @MainActor
    func testTheSupervisorDoesNotKeepThePlayerAlive() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)

        weak var weakPlayer: AVPlayer?
        weak var weakItem: AVPlayerItem?
        try autoreleasepool {
            let player = try XCTUnwrap(playback.makePlayer())
            weakPlayer = player
            weakItem = player.currentItem
            XCTAssertNotNil(playback.supervisor)
        }
        let released = try await waitUntil(.seconds(5)) { weakPlayer == nil && weakItem == nil }

        XCTAssertTrue(released, "the supervisor is a second owner of the player: "
                      + "player=\(weakPlayer == nil ? "released" : "alive") item=\(weakItem == nil ? "released" : "alive")")
        XCTAssertNotNil(playback.supervisor, "the supervisor outlives the player it watched")
        // Whatever AVFoundation still delivers after the player is gone must
        // not reach a dangling observation.
        try await Task.sleep(for: .milliseconds(300))
        withExtendedLifetime(playback) {}
    }

    /// The playback is what the lightbox retains for the presentation and
    /// releases on dismissal; everything under it — the supervisor and the
    /// loader with its chunk cache — must go with it. A supervisor whose
    /// `makeItem` closes over the playback would hold the `Retained` box that
    /// holds the supervisor, and none of it would ever be freed.
    @MainActor
    func testDroppingThePlaybackReleasesTheSupervisorAndTheLoader() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        weak var weakSupervisor: StreamingPlaybackSupervisor?
        weak var weakLoader: EncryptedStreamResourceLoader?
        try autoreleasepool {
            let loader = EncryptedStreamResourceLoader(session: session)
            let playback = StreamingPlayback(loader: loader, session: session)
            let player = try XCTUnwrap(playback.makePlayer())
            weakSupervisor = playback.supervisor
            weakLoader = loader
            XCTAssertNotNil(weakSupervisor)
            withExtendedLifetime(player) {}
        }
        let released = try await waitUntil(.seconds(5)) { weakSupervisor == nil && weakLoader == nil }
        XCTAssertTrue(released, "dropping the playback leaked: "
                      + "supervisor=\(weakSupervisor == nil ? "released" : "alive") "
                      + "loader=\(weakLoader == nil ? "released" : "alive")")
    }

    /// A pause with data buffered is the user's. Nothing about it is a stall,
    /// and the supervisor must not undo it.
    @MainActor
    func testAUserPauseWithDataBufferedIsLeftAlone() async throws {
        let store = InMemoryChunkedBlobStore()
        let session = try await makeMovieSession(name: "userpause", seconds: 3, store: store, backing: store)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        player.play()

        let playing = try await waitUntil {
            player.timeControlStatus == .playing && CMTimeGetSeconds(player.currentTime()) > 0.3
        }
        XCTAssertTrue(playing, "the clip never started: \(describe(player))")
        player.pause()
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertFalse(item.isPlaybackBufferEmpty, "a local clip must have data buffered when paused")

        try await Task.sleep(for: .seconds(1.5))

        XCTAssertEqual(player.timeControlStatus, .paused, "the supervisor restarted a user pause: \(describe(player))")
        XCTAssertEqual(supervisor.resumeCount, 0)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// A store whose first `failures` fetches of chunk 0 throw, then serves
    /// normally — the shape of a first request that AVFoundation gave up on.
    private actor FlakyFirstChunkStore: ChunkedBlobStoring {
        private let backing: ChunkedBlobStoring
        private var failuresRemaining: Int
        private(set) var chunkZeroFetches = 0

        init(backing: ChunkedBlobStoring, failures: Int) {
            self.backing = backing
            self.failuresRemaining = failures
        }

        struct Refused: Error {}

        func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
            if index == 0 {
                chunkZeroFetches += 1
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    throw Refused()
                }
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

    /// AVFoundation fails an item whose loading request errors out, and a failed
    /// item never recovers on its own. The supervisor replaces it with a fresh
    /// one over the same loader and carries on from where it was.
    @MainActor
    func testAFailedItemIsRebuiltAndPlays() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = FlakyFirstChunkStore(backing: backing, failures: 1)
        let session = try await makeMovieSession(name: "rebuild", seconds: 2, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        let firstItem = try XCTUnwrap(player.currentItem)
        player.play()

        // AVFoundation does not fail the item on the refused request itself; it
        // waits for bytes that never come and gives up after ~20 s with
        // NSURLErrorDomain -1001, the shape seen on device.
        let failed = try await waitUntil(.seconds(45)) { firstItem.status == .failed }
        XCTAssertTrue(failed, "the refused first request must fail the item: \(describe(player))")

        let recovered = try await waitUntil(.seconds(45)) {
            supervisor.rebuildCount == 1
                && player.currentItem !== firstItem
                && player.timeControlStatus == .playing
                && CMTimeGetSeconds(player.currentTime()) > 0.2
        }
        XCTAssertTrue(recovered, "rebuilds=\(supervisor.rebuildCount) \(describe(player))")
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        let fetches = await store.chunkZeroFetches
        XCTAssertEqual(fetches, 2, "one refused fetch, one that served the rebuilt item")
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// Two rebuilds at most. A third failure is left where the user can see it,
    /// instead of an endless loop of fresh items against a broken feed.
    @MainActor
    func testRebuildsStopAtTheBoundAndLeaveTheFailureVisible() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = FlakyFirstChunkStore(backing: backing, failures: StreamingPlaybackSupervisor.maxRebuilds + 1)
        let session = try await makeMovieSession(name: "exhausted", seconds: 2, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        player.play()

        // Each refused item takes AVFoundation ~20 s to fail.
        let exhausted = try await waitUntil(.seconds(45 * (StreamingPlaybackSupervisor.maxRebuilds + 1))) {
            supervisor.rebuildCount == StreamingPlaybackSupervisor.maxRebuilds && player.currentItem?.status == .failed
        }
        XCTAssertTrue(exhausted, "rebuilds=\(supervisor.rebuildCount) \(describe(player))")
        let lastItem = player.currentItem
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(supervisor.rebuildCount, StreamingPlaybackSupervisor.maxRebuilds)
        XCTAssertTrue(player.currentItem === lastItem, "no item may be minted past the bound")
        XCTAssertEqual(player.currentItem?.status, .failed, "the failure must stay visible: \(describe(player))")
        let fetches = await store.chunkZeroFetches
        XCTAssertEqual(fetches, StreamingPlaybackSupervisor.maxRebuilds + 1, "one fetch per item, none after the bound")
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// The lightbox pauses the player when the app resigns active, with
    /// whatever the buffer holds — often nothing. That pause is not a stall, and
    /// data arriving in the background must not restart a player the user is
    /// not looking at — even once the item reports it could keep up, which is
    /// exactly when an active-app stall would be resumed.
    @MainActor
    func testAPauseWhileTheAppIsInactiveIsNotAStall() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(400))
        let session = try await makeMovieSession(name: "inactive", seconds: 8, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)
        player.play()
        let started = try await waitUntil { CMTimeGetSeconds(player.currentTime()) > 0.1 }
        XCTAssertTrue(started, "the clip never started: \(describe(player))")

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let ranDry = try await waitUntil { player.timeControlStatus == .paused && item.isPlaybackBufferEmpty }
        XCTAssertTrue(ranDry, "the throttled feed never ran the player dry: \(describe(player))")
        let refilled = try await waitUntil(.seconds(30)) {
            !item.isPlaybackBufferEmpty && (item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull)
        }
        XCTAssertTrue(refilled, "the feed never caught up, so the resume gate was never open: \(describe(player))")
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(player.timeControlStatus, .paused, "an inactive app's player was restarted: \(describe(player))")
        XCTAssertEqual(supervisor.resumeCount, 0)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// Coming back to the foreground puts the supervisor back to work: a stall
    /// after `didBecomeActive` is resumed like any other.
    @MainActor
    func testStallsAreResumedAgainOnceTheAppIsActive() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(400))
        let session = try await makeMovieSession(name: "reactivated", seconds: 4, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        player.play()

        let duration = try await item.asset.load(.duration)
        let reachedEnd = try await waitUntil(.seconds(40)) {
            CMTimeGetSeconds(item.currentTime()) >= CMTimeGetSeconds(duration) - 0.5
        }
        XCTAssertTrue(reachedEnd, "watching did not resume with the app: \(describe(player))")
        XCTAssertGreaterThanOrEqual(supervisor.resumeCount, 1, "the clip outruns its feed, so a resume was due")
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// A switch the tests flip in place of the loader's own open-request report.
    private final class OpenRequestSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var open: Bool
        init(open: Bool) { self.open = open }
        var isOpen: Bool {
            get { lock.withLock { open } }
            set { lock.withLock { open = newValue } }
        }
    }

    /// Plays `player` and waits for the throttled feed to run it dry past
    /// `after` seconds of playback. AVFoundation sometimes posts a stall at 0 s
    /// before the first frame; that one is not the mid-play stall under test.
    @MainActor
    private func playUntilStalled(_ player: AVPlayer, _ item: AVPlayerItem,
                                  after: Double = 0.2, timeout: Duration = .seconds(20)) async throws {
        player.play()
        let stalled = try await waitUntil(timeout) {
            player.timeControlStatus == .paused && item.isPlaybackBufferEmpty
                && item.status == .readyToPlay && CMTimeGetSeconds(item.currentTime()) > after
        }
        XCTAssertTrue(stalled, "the throttled feed never ran the player dry past \(after)s: \(describe(player))")
    }

    /// The user pausing before anything has buffered looks like a stall from
    /// the buffer alone — empty, player paused — but AVFoundation posts no
    /// stalled notification for it. It must stay a pause: nothing resumes it
    /// when the data lands, and nothing rebuilds it for having no request open.
    @MainActor
    func testAUserPauseWithAnEmptyBufferIsNeitherResumedNorRebuilt() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 0, delay: .milliseconds(400))
        let session = try await makeMovieSession(name: "emptypause", seconds: 3, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let starvedAfter: TimeInterval = 0.5
        let player = try XCTUnwrap(playback.makePlayer(starvedAfter: starvedAfter, hasOpenDataRequest: { false }))
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)

        player.play()
        let left = try await waitUntil { player.timeControlStatus != .paused }
        XCTAssertTrue(left, "play() must take the player out of paused before the item is ready: \(describe(player))")
        player.pause()
        XCTAssertEqual(player.timeControlStatus, .paused)
        XCTAssertTrue(item.isPlaybackBufferEmpty, "the throttled feed must not have buffered anything yet: \(describe(player))")

        // The moment a misread stall would be resumed: the item is ready and
        // reports it could keep up.
        let buffered = try await waitUntil(.seconds(30)) {
            item.status == .readyToPlay && !item.isPlaybackBufferEmpty
                && (item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull)
        }
        XCTAssertTrue(buffered, "the feed never caught up, so nothing was tested: \(describe(player))")
        try await Task.sleep(for: .seconds(starvedAfter * 3 + 1))

        XCTAssertEqual(player.timeControlStatus, .paused, "the user's pause was undone: \(describe(player))")
        XCTAssertEqual(supervisor.resumeCount, 0)
        XCTAssertEqual(supervisor.rebuildCount, 0, "a user pause was rebuilt as a starved stall")
        XCTAssertTrue(player.currentItem === item)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// The failure seen on the rig: the player stalls, AVFoundation cancels its
    /// requests and never issues another, and the buffer stays empty however
    /// much is cached. With no data request open for `starvedAfter`, the
    /// supervisor rebuilds the item where it stopped and playback goes on.
    @MainActor
    func testAStarvedStallIsRebuiltFromCachedData() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(1_500))
        let session = try await makeMovieSession(name: "starved", seconds: 3, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        // Open until the mid-play stall is on, so an early stall takes the
        // ordinary path and the count below is this stall's alone.
        let signal = OpenRequestSignal(open: true)
        let starvedAfter: TimeInterval = 0.5
        let player = try XCTUnwrap(playback.makePlayer(starvedAfter: starvedAfter, hasOpenDataRequest: { signal.isOpen }))
        let supervisor = try XCTUnwrap(playback.supervisor)
        let firstItem = try XCTUnwrap(player.currentItem)
        try await playUntilStalled(player, firstItem)
        let stalledAt = CMTimeGetSeconds(firstItem.currentTime())
        XCTAssertEqual(supervisor.rebuildCount, 0)
        signal.isOpen = false

        let rebuilt = try await waitUntil(.seconds(starvedAfter * 3 + 2)) { supervisor.starvedRebuildCount == 1 }
        XCTAssertTrue(rebuilt, "a stall with no request open was not rebuilt: rebuilds=\(supervisor.rebuildCount) \(describe(player))")
        // Let the rebuilt item's own stalls take the ordinary path from here.
        signal.isOpen = true
        XCTAssertEqual(supervisor.rebuildCount, 1)
        XCTAssertTrue(player.currentItem !== firstItem, "the starved item must have been replaced")

        let advanced = try await waitUntil(.seconds(60)) {
            player.currentItem?.status == .readyToPlay
                && CMTimeGetSeconds(player.currentTime()) > stalledAt + 0.3
        }
        XCTAssertTrue(advanced, "the rebuilt item never played past \(stalledAt)s: \(describe(player))")
        XCTAssertEqual(supervisor.starvedRebuildCount, 1)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// A stall with a request open at the loader is the ordinary kind — the
    /// bytes are on their way — and must be resumed, not rebuilt.
    @MainActor
    func testAStallWithAnOpenRequestIsNotTreatedAsStarved() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(1_500))
        let session = try await makeMovieSession(name: "openstall", seconds: 3, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let starvedAfter: TimeInterval = 0.5
        let player = try XCTUnwrap(playback.makePlayer(starvedAfter: starvedAfter, hasOpenDataRequest: { true }))
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)
        try await playUntilStalled(player, item)

        try await Task.sleep(for: .seconds(starvedAfter * 3))
        XCTAssertEqual(supervisor.rebuildCount, 0, "a stall with a request open was rebuilt: \(describe(player))")
        XCTAssertTrue(player.currentItem === item)

        let duration = try await item.asset.load(.duration)
        let reachedEnd = try await waitUntil(.seconds(60)) {
            CMTimeGetSeconds(item.currentTime()) >= CMTimeGetSeconds(duration) - 0.5
        }
        XCTAssertTrue(reachedEnd, "the ordinary resume path stopped working: \(describe(player))")
        XCTAssertGreaterThanOrEqual(supervisor.resumeCount, 1)
        XCTAssertEqual(supervisor.rebuildCount, 0)
        XCTAssertEqual(supervisor.starvedRebuildCount, 0)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// A player that runs dry inside the last second of the item is waiting on
    /// its final bytes, not starved; replacing the item there would only replay
    /// the ending. The stall is placed there by when the first late chunk
    /// lands: the player stalls as it arrives, not as the buffer empties. The
    /// request signal stays open until then, so nothing earlier is starved.
    @MainActor
    func testStarvationAtTheEndOfTheItemDoesNotRebuild() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(1_200))
        let session = try await makeMovieSession(name: "ending", seconds: 2, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let signal = OpenRequestSignal(open: true)
        let starvedAfter: TimeInterval = 0.3
        let player = try XCTUnwrap(playback.makePlayer(starvedAfter: starvedAfter, hasOpenDataRequest: { signal.isOpen }))
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)
        let duration = CMTimeGetSeconds(try await item.asset.load(.duration))
        try await playUntilStalled(player, item, after: duration - StreamingPlaybackSupervisor.endTolerance)
        XCTAssertTrue(supervisor.isStallPending)
        XCTAssertEqual(supervisor.rebuildCount, 0)
        signal.isOpen = false

        try await Task.sleep(for: .seconds(starvedAfter * 3))
        XCTAssertTrue(supervisor.isStallPending, "the stall must outlast the check for it to have had its chance: \(describe(player))")
        XCTAssertEqual(supervisor.rebuildCount, 0, "a stall inside the end tolerance was rebuilt: \(describe(player))")
        XCTAssertTrue(player.currentItem === item)

        let reachedEnd = try await waitUntil(.seconds(30)) { CMTimeGetSeconds(item.currentTime()) >= duration - 0.5 }
        XCTAssertTrue(reachedEnd, "the feed never got the player to the end: \(describe(player))")
        XCTAssertEqual(supervisor.rebuildCount, 0)
        XCTAssertEqual(supervisor.starvedRebuildCount, 0)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// Starved rebuilds draw on the same budget as failed ones. Once two
    /// failed items have used it up, a starved stall is left pending — and the
    /// ordinary resume still takes it once the bytes arrive.
    @MainActor
    func testStarvedRebuildsRespectTheBound() async throws {
        let backing = InMemoryChunkedBlobStore()
        let throttled = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(1_500))
        let store = FlakyFirstChunkStore(backing: throttled, failures: StreamingPlaybackSupervisor.maxRebuilds)
        let session = try await makeMovieSession(name: "bounded", seconds: 3, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let starvedAfter: TimeInterval = 0.3
        let player = try XCTUnwrap(playback.makePlayer(starvedAfter: starvedAfter, hasOpenDataRequest: { false }))
        let supervisor = try XCTUnwrap(playback.supervisor)
        player.play()

        // Each refused item takes AVFoundation ~20 s to fail.
        let spent = try await waitUntil(.seconds(45 * StreamingPlaybackSupervisor.maxRebuilds)) {
            supervisor.rebuildCount == StreamingPlaybackSupervisor.maxRebuilds && player.currentItem?.status == .readyToPlay
        }
        XCTAssertTrue(spent, "rebuilds=\(supervisor.rebuildCount) \(describe(player))")
        XCTAssertEqual(supervisor.starvedRebuildCount, 0)
        let lastItem = try XCTUnwrap(player.currentItem)

        let stalled = try await waitUntil(.seconds(20)) {
            player.timeControlStatus == .paused && lastItem.isPlaybackBufferEmpty
                && lastItem.status == .readyToPlay && supervisor.isStallPending
        }
        XCTAssertTrue(stalled, "the last item never stalled: \(describe(player))")
        try await Task.sleep(for: .seconds(starvedAfter * 3))
        XCTAssertTrue(player.currentItem === lastItem, "an item was minted past the bound")
        XCTAssertEqual(supervisor.rebuildCount, StreamingPlaybackSupervisor.maxRebuilds)
        XCTAssertEqual(supervisor.starvedRebuildCount, 0)

        let duration = try await lastItem.asset.load(.duration)
        let reachedEnd = try await waitUntil(.seconds(60)) {
            CMTimeGetSeconds(lastItem.currentTime()) >= CMTimeGetSeconds(duration) - 0.5
        }
        XCTAssertTrue(reachedEnd, "the ordinary resume stopped working past the bound: \(describe(player))")
        XCTAssertNotEqual(lastItem.status, .failed)
        XCTAssertGreaterThanOrEqual(supervisor.resumeCount, 1)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// `contentLength` must be the PLAINTEXT length. Reporting the ENC3 file size
    /// would make AVPlayer request bytes past the end of the media and mis-seek.
    func testSessionReportsPlaintextLengthNotCiphertextLength() async throws {
        let (session, _, plaintext) = try await makeSession(bytes: 10_000, chunkSize: 1_000)
        XCTAssertEqual(session.plaintextLength, plaintext.count)
        XCTAssertLessThan(session.plaintextLength, session.geometry.totalCiphertextLength,
                          "ciphertext is strictly larger; the two must not be confused")
    }

    // MARK: - The AVFoundation contract, driven by a real AVPlayer

    /// The one thing the slices tests above cannot prove: that AVFoundation
    /// *accepts* what the delegate hands it, end to end — custom scheme, delegate
    /// wiring, content information, byte-range requests, decryption, and a real
    /// decode.
    ///
    /// Runs here rather than in a UI test because the unit bundle has a host app, so
    /// AVPlayer works: a ~15s app launch becomes a sub-second check.
    ///
    /// **Scope, established by mutation-testing rather than assumed.** This test
    /// does NOT catch either of the two contract details the loader is careful
    /// about: answering the ~2-byte data request attached to the info request, and
    /// reporting the ciphertext length as `contentLength`. Both mutations leave it
    /// passing on iOS 26 — AVFoundation tolerates them for a short clip. What it
    /// does catch is a broken scheme or delegate wiring, wrong geometry, a bad
    /// range mapping, and any decryption failure; those are the failures that
    /// actually produce a black frame.
    @MainActor
    func testRealAVPlayerBecomesReadyAndDecodesAFrameThroughTheLoader() async throws {
        let movie = tempDir.appendingPathComponent("clip.mov")
        try await Self.writeTinyMovie(to: movie, seconds: 2)

        let enc3 = tempDir.appendingPathComponent("clip.enc3")
        // 16 KB chunks so even a short clip spans many chunks.
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 16 * 1024)
            .encrypt(source: movie, destination: enc3)

        let store = InMemoryChunkedBlobStore()
        let header = try await store.uploadChunks(enc3FileURL: enc3, mediaRecordName: "clip", progress: { _ in })
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "clip",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 3)
        XCTAssertGreaterThan(session.geometry.chunkCount, 4, "fixture should span several chunks")

        let loader = EncryptedStreamResourceLoader(session: session)
        let item = try XCTUnwrap(loader.makePlayerItem())
        let player = AVPlayer(playerItem: item)

        var ready = false
        for _ in 0..<200 {
            if item.status == .readyToPlay { ready = true; break }
            if item.status == .failed {
                XCTFail("player item failed: \(item.error.map { "\($0)" } ?? "unknown")")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(ready, "AVPlayer never accepted the streamed asset")

        let duration = try await item.asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.5,
                       "the streamed asset must report the real duration")

        // A frame can only decode if chunks were fetched, authenticated, decrypted
        // and reassembled into a valid MOV byte range.
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// Every loading request AVFoundation issues is traced from receipt to its
    /// outcome, so a stall on a device can be read as "the player stopped asking"
    /// or "the loader stopped answering" from the log alone.
    ///
    /// Asserted per request and in sequence, not by set membership: `received`
    /// first; exactly one outcome (`finished`, `cancelled` or `failed`) and it is the
    /// last line; `contentInfo` only on the information request, straight after
    /// receipt and before its `finished`; only `slice` lines in between, with
    /// `chunk=` and `total=` strictly increasing. The one tolerance is the slice
    /// already past the loader's cancellation check when `didCancel` lands: it may
    /// still trace after `cancelled`, the same in-flight allowance
    /// `testCancellingTheStreamStopsFetching` makes. Nothing may follow `finished`.
    ///
    /// This is also the guard that a fully served data request is *finished* rather
    /// than left open. `AVAssetResourceLoadingRequest` has no public initializer, so
    /// there is no fake to observe `finishLoading()` on; the `finished` line the loader
    /// emits immediately after that call is the observable, and at least one data
    /// request that delivered slices must reach it.
    @MainActor
    func testEveryLoadingRequestIsTracedFromReceiptToOutcome() async throws {
        let movie = tempDir.appendingPathComponent("traced.mov")
        try await Self.writeTinyMovie(to: movie, seconds: 1)
        let enc3 = tempDir.appendingPathComponent("traced.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 16 * 1024)
            .encrypt(source: movie, destination: enc3)
        let store = InMemoryChunkedBlobStore()
        let header = try await store.uploadChunks(enc3FileURL: enc3, mediaRecordName: "traced", progress: { _ in })
        let session = ChunkedStreamSession.open(store: store, mediaRecordName: "traced", header: header, keyBytes: key)

        let loader = EncryptedStreamResourceLoader(session: session)
        let lines = LockedLines()
        loader.traceSink = { lines.append($0) }
        let item = try XCTUnwrap(loader.makePlayerItem())
        let player = AVPlayer(playerItem: item)

        var polls = 0
        while item.status == .unknown, polls < 200 {
            try await Task.sleep(for: .milliseconds(50))
            polls += 1
        }
        XCTAssertEqual(item.status, .readyToPlay, "item error: \(item.error.map { "\($0)" } ?? "none")")

        // Wait until every request received so far has an outcome and the trace has
        // gone quiet, so a request AVFoundation issues after readiness is judged on
        // its outcome rather than on where the snapshot happened to fall. A request
        // that never reaches an outcome runs this to the deadline and fails below.
        var trace = lines.snapshot()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(250))
            let next = lines.snapshot()
            let quiet = next.count == trace.count
            trace = next
            if quiet, Self.requests(in: trace).allSatisfy({ $0.events.contains { Self.outcomes.contains($0.kind) } }) {
                break
            }
        }

        XCTAssertTrue(trace.allSatisfy { !$0.contains("\n") }, "one line per event")
        let requests = Self.requests(in: trace)
        XCTAssertFalse(requests.isEmpty, "no loading request was traced: \(trace)")
        XCTAssertEqual(requests.count, Set(requests.map(\.id)).count, "request ids must be unique: \(trace)")
        for line in trace where Self.parse(line) == nil {
            XCTFail("unparseable trace line: \(line)")
        }

        var informationRequests = 0
        var fullyServedDataRequests = 0
        for request in requests {
            let events = request.events
            let kinds = events.map(\.kind)
            let label = "request \(request.id) \(kinds)"

            XCTAssertEqual(kinds.first, "received", "\(label): an outcome was traced for a request that was never received: \(trace)")
            let outcomeIndices = kinds.indices.filter { Self.outcomes.contains(kinds[$0]) }
            XCTAssertEqual(outcomeIndices.count, 1, "\(label): every request must reach exactly one outcome within the wait: \(trace)")
            guard let received = events.first, received.kind == "received", let outcomeIndex = outcomeIndices.first else { continue }
            let outcome = events[outcomeIndex]
            XCTAssertNotEqual(outcome.kind, "failed", "\(label): no request should fail: \(trace)")

            let between = kinds[1..<outcomeIndex]
            XCTAssertTrue(between.allSatisfy { $0 == "contentInfo" || $0 == "slice" },
                          "\(label): only contentInfo and slice lines may appear between receipt and outcome")
            let after = kinds[(outcomeIndex + 1)...]
            if outcome.kind == "cancelled" {
                XCTAssertTrue(after.count <= 1 && after.allSatisfy { $0 == "slice" },
                              "\(label): only the one slice already past the cancellation check may trace after cancelled")
            } else {
                XCTAssertTrue(after.isEmpty, "\(label): \(outcome.kind) must be the last line traced for the request: \(trace)")
            }

            let slices = events.filter { $0.kind == "slice" }
            let infoLines = events.filter { $0.kind == "contentInfo" }
            if received.fields["info"] == "true" {
                informationRequests += 1
                XCTAssertEqual(kinds, ["received", "contentInfo", "finished"],
                               "\(label): the content-information request is answered on receipt and finished synchronously, "
                               + "with its attached data request left unanswered")
                XCTAssertEqual(infoLines.first?.fields["length"], "\(session.plaintextLength)",
                               "\(label): contentInfo must report the plaintext length")
            } else {
                XCTAssertTrue(infoLines.isEmpty, "\(label): contentInfo traced for a plain data request")
            }

            let chunks = slices.compactMap { $0.fields["chunk"].flatMap(Int.init) }
            let bytes = slices.compactMap { $0.fields["bytes"].flatMap(Int.init) }
            let totals = slices.compactMap { $0.fields["total"].flatMap(Int.init) }
            XCTAssertEqual(chunks.count, slices.count, "\(label): every slice must name its chunk")
            XCTAssertEqual(totals.count, slices.count, "\(label): every slice must carry the running total")
            XCTAssertTrue(zip(chunks, chunks.dropFirst()).allSatisfy { $0 < $1 },
                          "\(label): slices must arrive in strictly ascending chunk order: \(chunks)")
            XCTAssertTrue(zip(totals, totals.dropFirst()).allSatisfy { $0 < $1 },
                          "\(label): the running total must strictly increase: \(totals)")
            var running = 0
            let cumulative = bytes.map { running += $0; return running }
            XCTAssertEqual(totals, cumulative, "\(label): total= must be the sum of the slices so far")

            if outcome.kind == "finished" {
                XCTAssertEqual(outcome.fields["bytes"].flatMap(Int.init), totals.last ?? 0,
                               "\(label): finished must report the bytes the slices delivered")
                if received.fields["info"] != "true", !slices.isEmpty { fullyServedDataRequests += 1 }
            }
        }

        XCTAssertEqual(informationRequests, 1, "exactly one content-information request is expected: \(trace)")
        XCTAssertGreaterThan(requests.count, informationRequests,
                             "AVFoundation must have followed up with a data request: \(trace)")
        XCTAssertGreaterThan(fullyServedDataRequests, 0,
                             "no data request was served to completion and finished; a request left open after its last "
                             + "slice is exactly the stall this trace exists to diagnose: \(trace)")

        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// `hasOpenDataRequest` is what tells a stalled player apart from one that
    /// has stopped asking, so it must hold only while a data request is being
    /// served: not for the content-information request, which is answered on
    /// receipt, and not once every request has finished or been cancelled.
    @MainActor
    func testHasOpenDataRequestHoldsOnlyWhileADataRequestIsBeingServed() async throws {
        let store = InMemoryChunkedBlobStore()
        let session = try await makeMovieSession(name: "open", seconds: 1, store: store, backing: store)
        await store.setChunkLatency(.milliseconds(300))
        let loader = EncryptedStreamResourceLoader(session: session)
        XCTAssertFalse(loader.hasOpenDataRequest, "nothing has been asked for yet")

        // Sampled from inside the sink, so each line carries the property's
        // value at the moment the event happened.
        let observed = LockedLines()
        loader.traceSink = { [weak loader] line in
            guard let loader else { return }
            observed.append("\(line) open=\(loader.hasOpenDataRequest) count=\(loader.openDataRequestCount)")
        }
        let item = try XCTUnwrap(loader.makePlayerItem())
        let player = AVPlayer(playerItem: item)

        let sawSlice = try await waitUntil(.seconds(15)) {
            observed.snapshot().contains { $0.hasPrefix("loadingRequest slice") }
        }
        XCTAssertTrue(sawSlice, "no data request was served: \(observed.snapshot())")
        let lines = observed.snapshot()
        let infoLines = lines.filter { $0.hasPrefix("loadingRequest contentInfo") }
        XCTAssertFalse(infoLines.isEmpty, "the content-information request was not traced: \(lines)")
        for line in infoLines {
            XCTAssertTrue(line.hasSuffix(" open=false count=0"),
                          "the content-information request must not count as an open data request: \(line)")
        }
        for line in lines where line.hasPrefix("loadingRequest slice") {
            XCTAssertTrue(line.contains(" open=true"), "a request mid-delivery is open: \(line)")
        }

        // Taking the item away cancels whatever is still outstanding.
        player.replaceCurrentItem(with: nil)
        let settled = try await waitUntil(.seconds(15)) { !loader.hasOpenDataRequest }
        XCTAssertTrue(settled, "requests still open after the item was dropped: \(observed.snapshot())")
        XCTAssertEqual(loader.openDataRequestCount, 0)
        let outcomes = observed.snapshot().filter {
            $0.hasPrefix("loadingRequest finished") || $0.hasPrefix("loadingRequest cancelled")
        }
        XCTAssertFalse(outcomes.isEmpty, "every request must reach finished or cancelled: \(observed.snapshot())")

        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    private static let outcomes: Set<String> = ["finished", "cancelled", "failed"]

    private struct TraceEvent {
        let kind: String
        let id: Int
        let fields: [String: String]
    }

    /// `loadingRequest <kind> id=<n> key=value …`; tokens without `=` are flags and ignored.
    private static func parse(_ line: String) -> TraceEvent? {
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count >= 3, tokens[0] == "loadingRequest" else { return nil }
        var fields: [String: String] = [:]
        for token in tokens.dropFirst(2) {
            guard let eq = token.firstIndex(of: "=") else { continue }
            fields[String(token[..<eq])] = String(token[token.index(after: eq)...])
        }
        guard let id = fields["id"].flatMap(Int.init) else { return nil }
        return TraceEvent(kind: tokens[1], id: id, fields: fields)
    }

    /// The trace grouped per request id, each request's events in emission order,
    /// requests in order of first appearance.
    private static func requests(in trace: [String]) -> [(id: Int, events: [TraceEvent])] {
        var order: [Int] = []
        var byID: [Int: [TraceEvent]] = [:]
        for event in trace.compactMap(parse) {
            if byID[event.id] == nil { order.append(event.id) }
            byID[event.id, default: []].append(event)
        }
        return order.map { ($0, byID[$0] ?? []) }
    }

    private final class LockedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        func snapshot() -> [String] { lock.withLock { lines } }
    }

    /// A small real H.264 MOV. Noise frames so the encoder cannot compress it to a
    /// size that would leave the clip spanning a single chunk.
    /// `fastStart` puts the `moov` atom first, the way a camera capture is
    /// written, so a player can become ready before the whole file has arrived.
    static func writeTinyMovie(to url: URL, seconds: Int, fastStart: Bool = false) async throws {
        let side = 240
        let fps: Int32 = 15
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = fastStart
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var state: UInt64 = 0x13579BDF2468ACE0
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let pointer = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<side {
                    let row = pointer + y * bytesPerRow
                    for x in stride(from: 0, to: side * 4, by: 4) {
                        state = state &* 6364136223846793005 &+ 1442695040888963407
                        let value = UInt8(truncatingIfNeeded: state >> 33)
                        row[x] = 255
                        row[x + 1] = value
                        row[x + 2] = value &+ 61
                        row[x + 3] = value &+ 127
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
