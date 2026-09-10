//
//  EncryptedStreamResourceLoader.swift
//  EncameraCore
//
//  Feeds AVPlayer decrypted bytes on demand, so a CloudKit-backed video plays
//  without ever existing as a plaintext file on disk and without waiting for the
//  whole blob to download.
//
//  Constraints that shaped this, all of them load-bearing:
//
//  - **The URL must use a custom scheme.** `AVAssetResourceLoaderDelegate` is never
//    consulted for `http`/`https` URLs. Hence `encamera-enc://`. This one is
//    verified: `testPlayerItemUsesTheCustomSchemeSoTheDelegateIsConsulted`.
//  - **The tiny data request attached to the content-information request is left
//    unanswered.** The widely-cited reason is a bug where answering it stops all
//    further loading requests. That claim is from 2016 and does *not* reproduce on
//    iOS 26 — mutation-testing the loader to answer it leaves
//    `testRealAVPlayerBecomesReadyAndDecodesAFrameThroughTheLoader` passing. The
//    behaviour is kept because it is the documented shape and costs nothing, but no
//    test here demonstrates that answering is unsafe.
//  - **`contentLength` is the PLAINTEXT length**, not the ENC3 file size. AVPlayer
//    is being handed a virtual, already-decrypted resource; the ciphertext framing
//    must be invisible to it. Note AVFoundation is lenient about an over-long
//    `contentLength` — mutating this to the ciphertext size also leaves the player
//    test passing, because duration comes from the `moov` atom and the phantom tail
//    is never read. The guard that actually holds is that every range served is
//    derived from `session.plaintextLength`.
//  - **Video AirPlay does not work with a custom resource loader.** This is Apple's
//    position via DTS and has not changed. PiP is fine. If AirPlay is ever required
//    for CloudKit video, this approach has to be replaced by a loopback HTTP server
//    — see the report §6 option B.
//
//  Delegate callbacks arrive on the queue given to `setDelegate(_:queue:)`, which
//  must be serial and must not be the main queue.
//

import Foundation
import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// URL scheme that routes an `AVURLAsset` through this loader.
public enum EncryptedStreamScheme {
    public static let scheme = "encamera-enc"

    public static func url(mediaRecordName: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "media"
        components.path = "/" + mediaRecordName
        return components.url
    }

    public static func mediaRecordName(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let name = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        return name.isEmpty ? nil : name
    }
}

/// How a player fed by the resource loader buffers and starts.
///
/// Left to its defaults, AVPlayer treats the loader like a network stream and
/// holds the first frame under `toMinimizeStalls` until its stall estimator is
/// satisfied — on a cold CloudKit feed that was ~32 MiB and over two minutes,
/// with the item `readyToPlay` after the first chunk. The estimator assumes it
/// can predict future availability, which a delegate-fed asset defeats; the
/// AVFoundation header says as much and tells resource-loader clients to turn
/// the waiting off.
public struct StreamingPlaybackPolicy: Sendable, Equatable {
    /// Seconds of media the player is asked to keep buffered ahead of the
    /// playhead. The production fixture is ~1.8 MB/s, so one 4 MiB chunk holds
    /// about 2.3 s of media; 3 s is a chunk and a little of the next, rather than
    /// the ~18 s the player accumulated when left to choose.
    public var preferredForwardBufferDuration: TimeInterval
    /// `false`: `play()` starts on the first decodable media and a dry buffer
    /// stalls in place, instead of pre-buffering against a stall estimate.
    public var automaticallyWaitsToMinimizeStalling: Bool
    /// Chunks the source fetches speculatively behind each one the player asked
    /// for. Cold, CloudKit hands over 4 MiB chunks at ~0.25 MB/s no matter how
    /// many are in flight, so every speculative transfer shares the link with
    /// the chunk the player is blocked on: at 3 the median chunk took 52-61 s,
    /// at 1 it took 14 s with the full-read time unchanged.
    public var readAhead: Int

    public init(preferredForwardBufferDuration: TimeInterval,
                automaticallyWaitsToMinimizeStalling: Bool,
                readAhead: Int) {
        self.preferredForwardBufferDuration = preferredForwardBufferDuration
        self.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
        self.readAhead = readAhead
    }

    /// The policy for a video streamed out of CloudKit.
    public static let cloudKit = StreamingPlaybackPolicy(preferredForwardBufferDuration: 3,
                                                         automaticallyWaitsToMinimizeStalling: false,
                                                         readAhead: 1)
}

/// Everything a presenter needs to stream one chunked video through a stock
/// AVPlayer. The loader must stay retained for the item's lifetime —
/// `AVURLAsset` holds its resource-loader delegate weakly, and a deallocated
/// delegate is indistinguishable from a video that never loads.
///
/// Holds no player and no item: the `AVPlayerViewController` that presents the
/// player must be its only owner, so that dismissing it stops playback. Items
/// are minted by `makePlayerItem()` and tuned by `policy`; `makePlayer()`
/// applies the player half. A bare `AVPlayer(playerItem:)` over an item would
/// wait to minimize stalls again.
public struct StreamingPlayback {
    public let loader: EncryptedStreamResourceLoader
    public let session: ChunkedStreamSession
    public let policy: StreamingPlaybackPolicy
    /// Lives here rather than on the player so that whoever retains the
    /// playback for the presentation's lifetime retains the supervisor with it.
    private let retained = Retained()

    private final class Retained {
        var supervisor: StreamingPlaybackSupervisor?
    }

    /// The supervisor watching the player `makePlayer()` last built, if any.
    public var supervisor: StreamingPlaybackSupervisor? { retained.supervisor }

    public init(loader: EncryptedStreamResourceLoader,
                session: ChunkedStreamSession,
                policy: StreamingPlaybackPolicy = .cloudKit) {
        self.loader = loader
        self.session = session
        self.policy = policy
    }

    /// A fresh item over the loader, buffering as `policy` says.
    public func makePlayerItem() -> AVPlayerItem? {
        Self.makeItem(loader: loader, policy: policy)
    }

    private static func makeItem(loader: EncryptedStreamResourceLoader, policy: StreamingPlaybackPolicy) -> AVPlayerItem? {
        guard let item = loader.makePlayerItem() else { return nil }
        item.preferredForwardBufferDuration = policy.preferredForwardBufferDuration
        return item
    }

    /// A player over a fresh item, configured by `policy`, with a supervisor
    /// watching it for as long as this playback is retained. `nil` only when
    /// the session's record name cannot form a URL.
    public func makePlayer() -> AVPlayer? {
        makePlayer(starvedAfter: StreamingPlaybackSupervisor.defaultStarvedAfter, hasOpenDataRequest: nil)
    }

    /// `hasOpenDataRequest` stands in for the loader's own report; tests use
    /// it to drive the starved-player check without a starving store.
    func makePlayer(starvedAfter: TimeInterval, hasOpenDataRequest: (() -> Bool)?) -> AVPlayer? {
        guard let item = makePlayerItem() else { return nil }
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = policy.automaticallyWaitsToMinimizeStalling
        // The closures capture the loader and policy, not `self`: a closure
        // over this struct would hold `retained`, which holds the supervisor,
        // which holds the closure.
        let loader = loader
        let policy = policy
        retained.supervisor = policy.automaticallyWaitsToMinimizeStalling
            ? nil
            : StreamingPlaybackSupervisor(player: player,
                                          item: item,
                                          policy: policy,
                                          starvedAfter: starvedAfter,
                                          hasOpenDataRequest: hasOpenDataRequest ?? { [weak loader] in loader?.hasOpenDataRequest ?? false },
                                          makeItem: { Self.makeItem(loader: loader, policy: policy) })
        return player
    }
}

/// Keeps a streamed player going through the ways AVFoundation gives up on a
/// delegate-fed asset.
///
/// **Stalls.** With `automaticallyWaitsToMinimizeStalling` off, a buffer that
/// runs dry mid-playback drops the player to `.paused` at rate 0 and nothing
/// restarts it. AVFoundation posts `AVPlayerItemPlaybackStalled` for that
/// pause, which is what tells it apart from the user's: a pause inside
/// `stallPairingWindow` of a stalled notification is the stall's whatever the
/// buffer holds; outside it, a pause with data buffered is the user's, and so
/// is one with an empty buffer that no notification follows within the
/// window. A user's pause cancels a pending resume. A stall is resumed with `play()`
/// once the item reports it is likely to keep up, or that its buffer is full
/// and nothing more can be loaded. Nothing is a stall while the app is
/// inactive — the lightbox pauses the player on resign, usually with an empty
/// buffer, and data arriving in the background must not restart it.
///
/// **Starvation.** A stalled player normally has a loading request open at
/// the loader, and the resume above follows the bytes. Sometimes it has none:
/// AVFoundation cancels its requests after a stall, re-reads what it already
/// has and never asks for the next byte, so the buffer stays empty however
/// much has been cached. While a stall is pending the supervisor checks once
/// a second, and a player that has had no open data request for
/// `starvedAfter` gets its item rebuilt at the current time — unless it is
/// within `endTolerance` of the end, the app is inactive, or a seek is in
/// flight.
///
/// **Failures.** AVFoundation fails an item outright when a loading request has
/// produced no byte for roughly 20 s (`NSURLErrorDomain -1001`), and a failed
/// item never recovers. The item is replaced with a fresh one over the same
/// loader — chunks already fetched are served from the session's cache — and
/// playback resumes from where it was. Failed and starved rebuilds share one
/// budget of `maxRebuilds`; after that the player is left as it is.
///
/// Holds the player and item weakly. The presenting `AVPlayerViewController`
/// is their only owner, so that dismissing it stops playback; once it lets go,
/// the observations here have nothing to fire on. All state is touched on the
/// main queue; AVFoundation delivers the observations from its own threads.
public final class StreamingPlaybackSupervisor: DebugPrintable {

    /// How many times an item is replaced, for any reason, before the player
    /// is left as it is.
    public static let maxRebuilds = 2
    /// How long a stalled player may go without a single open data request
    /// before its item is rebuilt.
    public static let defaultStarvedAfter: TimeInterval = 5
    /// A stall this close to the end of the item is left to play out.
    static let endTolerance: TimeInterval = 1
    /// How far apart a pause with an empty buffer and a stalled notification
    /// may be and still be the same stall.
    static let stallPairingWindow: TimeInterval = 1

    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private let policy: StreamingPlaybackPolicy
    private let starvedAfter: TimeInterval
    private let hasOpenDataRequest: () -> Bool
    private let makeItem: () -> AVPlayerItem?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotificationObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var resumePending = false {
        didSet {
            guard resumePending != oldValue else { return }
            if resumePending { startStarvationWatch() } else { stopStarvationWatch() }
        }
    }
    /// Set between `willResignActive` and `didBecomeActive`.
    private var appInactive = false
    /// Set by a pause that was the user's, cleared once the player moves again.
    private var userPaused = false
    private var lastStalledNotification: Date?
    /// Decides a pause with an empty buffer once the pairing window closes.
    private var pauseClassification: DispatchWorkItem?
    /// Where a rebuilt item should pick up, applied once it is ready to play.
    private var pendingRebuildResume: CMTime?
    /// Set around the supervisor's own seek into a rebuilt item.
    private var seekInProgress = false
    private var starvationTimer: Timer?
    /// The last moment the loader was seen with a data request open, or the
    /// playhead was seen to move, while the current stall has been pending.
    private var lastActivity = Date()
    /// Whether a stall is waiting on data right now.
    public var isStallPending: Bool { resumePending }
    /// How many stalls have been resumed so far.
    public private(set) var resumeCount = 0
    /// How many items have been replaced so far, for any reason.
    public private(set) var rebuildCount = 0
    /// How many of those replaced a starved player rather than a failed item.
    public private(set) var starvedRebuildCount = 0

    init(player: AVPlayer,
         item: AVPlayerItem,
         policy: StreamingPlaybackPolicy,
         starvedAfter: TimeInterval = StreamingPlaybackSupervisor.defaultStarvedAfter,
         hasOpenDataRequest: @escaping () -> Bool,
         makeItem: @escaping () -> AVPlayerItem?) {
        self.player = player
        self.item = item
        self.policy = policy
        self.starvedAfter = starvedAfter
        self.hasOpenDataRequest = hasOpenDataRequest
        self.makeItem = makeItem
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                self?.onMain { $0.noteStatusChange() }
            }
        ]
        watch(item)
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.appInactive = true
                self?.resumePending = false
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.appInactive = false
            }
        ]
    }

    deinit {
        starvationTimer?.invalidate()
        pauseClassification?.cancel()
        let center = NotificationCenter.default
        for observer in itemNotificationObservers + appObservers { center.removeObserver(observer) }
    }

    private func onMain(_ body: @escaping (StreamingPlaybackSupervisor) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }

    /// Points every per-item observation at `item`, dropping the previous
    /// item's.
    private func watch(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        for observer in itemNotificationObservers { center.removeObserver(observer) }
        self.item = item
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                self?.onMain { $0.noteItemStatus() }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
                self?.onMain { $0.resumeIfReady(trigger: "likelyToKeepUp") }
            },
            item.observe(\.isPlaybackBufferFull, options: [.new]) { [weak self] _, _ in
                self?.onMain { $0.resumeIfReady(trigger: "bufferFull") }
            }
        ]
        itemNotificationObservers = [
            center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
                guard let self else { return }
                lastStalledNotification = Date()
                pauseClassification?.cancel()
                pauseClassification = nil
                noteStall(trigger: "stalledNotification")
            },
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.resumePending = false
            },
            center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak self] _ in
                self?.lastActivity = Date()
            }
        ]
    }

    // MARK: Stalls

    private func noteStatusChange() {
        guard let player, let item, pendingRebuildResume == nil, !seekInProgress else { return }
        guard player.timeControlStatus == .paused else {
            userPaused = false
            pauseClassification?.cancel()
            pauseClassification = nil
            return
        }
        // The notification decides before the buffer does: by the time the
        // pause is processed, bytes may already have landed for a stall that
        // was posted first.
        if let stalled = lastStalledNotification, Date().timeIntervalSince(stalled) <= Self.stallPairingWindow {
            noteStall(trigger: "pausedAfterStalledNotification")
        } else if !item.isPlaybackBufferEmpty {
            noteUserPause(trigger: "pausedWithData")
        } else {
            classifyPauseAfterWindow()
        }
    }

    /// A pause with nothing buffered is the stall's if AVFoundation says so
    /// inside the pairing window, and the user's otherwise.
    private func classifyPauseAfterWindow() {
        pauseClassification?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let player, player.timeControlStatus == .paused, !resumePending else { return }
            noteUserPause(trigger: "pausedWithEmptyBufferUnstalled")
        }
        pauseClassification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallPairingWindow, execute: work)
    }

    private func noteUserPause(trigger: String) {
        guard let item else { return }
        userPaused = true
        resumePending = false
        printDebug("user pause trigger=\(trigger) time=\(Int(CMTimeGetSeconds(item.currentTime()) * 1000))ms")
    }

    private func noteStall(trigger: String) {
        guard !appInactive, let item else { return }
        if !resumePending {
            userPaused = false
            resumePending = true
            printDebug("stall pending trigger=\(trigger) time=\(Int(CMTimeGetSeconds(item.currentTime()) * 1000))ms")
        }
        // The item may already report it can keep up, in which case no
        // observation is coming to trigger the resume.
        resumeIfReady(trigger: trigger)
    }

    private func resumeIfReady(trigger: String) {
        guard resumePending, !appInactive, !userPaused,
              let player, let item,
              player.timeControlStatus == .paused,
              !item.isPlaybackBufferEmpty,
              item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull else { return }
        resumePending = false
        resumeCount += 1
        printDebug("stall resumed trigger=\(trigger) count=\(resumeCount) "
                   + "time=\(Int(CMTimeGetSeconds(item.currentTime()) * 1000))ms")
        player.play()
    }

    // MARK: Starvation

    private func startStarvationWatch() {
        lastActivity = Date()
        starvationTimer?.invalidate()
        let timer = Timer(timeInterval: min(1, starvedAfter), repeats: true) { [weak self] _ in
            self?.checkStarvation()
        }
        RunLoop.main.add(timer, forMode: .common)
        starvationTimer = timer
    }

    private func stopStarvationWatch() {
        starvationTimer?.invalidate()
        starvationTimer = nil
    }

    private func checkStarvation() {
        guard resumePending, !appInactive, !userPaused, !seekInProgress, pendingRebuildResume == nil,
              let player, let item,
              player.timeControlStatus == .paused,
              item.status == .readyToPlay,
              item.isPlaybackBufferEmpty else { return }
        if hasOpenDataRequest() {
            lastActivity = Date()
            return
        }
        let remaining = CMTimeGetSeconds(item.duration) - CMTimeGetSeconds(item.currentTime())
        if remaining.isFinite, remaining <= Self.endTolerance { return }
        guard Date().timeIntervalSince(lastActivity) >= starvedAfter else { return }
        rebuild(reason: "starved")
        // A rebuild clears the pending stall and with it the watch; past the
        // bound the stall stays pending, and one report of it is enough.
        stopStarvationWatch()
    }

    // MARK: Failures

    private func noteItemStatus() {
        guard let item else { return }
        switch item.status {
        case .failed:
            rebuild(reason: item.error.map { ($0 as NSError).domain + ":" + String(($0 as NSError).code) } ?? "unknown")
        case .readyToPlay:
            guard let time = pendingRebuildResume else { return }
            pendingRebuildResume = nil
            resumeRebuilt(at: time)
        default:
            break
        }
    }

    private func rebuild(reason: String) {
        guard let player, let current = item, !appInactive else { return }
        let at = current.currentTime()
        let seconds = CMTimeGetSeconds(at)
        guard rebuildCount < Self.maxRebuilds else {
            printDebug("playback rebuild exhausted n=\(rebuildCount) at=\(seconds)s reason=\(reason)")
            return
        }
        guard let fresh = makeItem() else { return }
        rebuildCount += 1
        if reason == "starved" { starvedRebuildCount += 1 }
        printDebug("playback rebuild n=\(rebuildCount) at=\(seconds)s reason=\(reason)")
        resumePending = false
        pendingRebuildResume = seconds.isFinite && seconds > 0 ? at : .zero
        watch(fresh)
        player.replaceCurrentItem(with: fresh)
        player.automaticallyWaitsToMinimizeStalling = policy.automaticallyWaitsToMinimizeStalling
    }

    private func resumeRebuilt(at time: CMTime) {
        guard let player else { return }
        if time == .zero {
            player.play()
            return
        }
        seekInProgress = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { [weak self, weak player] _ in
            DispatchQueue.main.async {
                self?.seekInProgress = false
                player?.play()
            }
        }
    }
}

/// Serves plaintext byte ranges to AVFoundation out of a `ChunkedStreamSession`.
public final class EncryptedStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, DebugPrintable {

    private let session: ChunkedStreamSession
    private let contentType: String
    /// One `Task` per outstanding loading request, so `didCancel` can actually stop
    /// the work rather than leaving it to run to completion invisibly.
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// One trace record per outstanding loading request, so a cancel can report
    /// how far the request had got.
    private var traces: [ObjectIdentifier: RequestTrace] = [:]
    private var nextRequestID = 1
    private let lock = NSLock()

    /// Where the per-request trace lines go. `nil` sends them to `printDebug`;
    /// tests install a sink to assert on them.
    var traceSink: ((String) -> Void)?

    /// What has happened to one loading request so far.
    private final class RequestTrace {
        let id: Int
        /// False for the content-information request, whose attached data
        /// request is deliberately left unanswered.
        let servesData: Bool
        let started = Date()
        var bytes = 0

        init(id: Int, servesData: Bool) {
            self.id = id
            self.servesData = servesData
        }

        var elapsedMs: Int { Int(Date().timeIntervalSince(started) * 1000) }
    }

    /// Data requests AVFoundation has issued and not yet seen finished, failed
    /// or cancelled. The content-information request does not count: it is
    /// answered on receipt, and its attached data request is never served.
    public var openDataRequestCount: Int {
        lock.withLock { traces.values.reduce(0) { $0 + ($1.servesData ? 1 : 0) } }
    }

    /// Whether AVFoundation is waiting on bytes right now. A stalled player
    /// with nothing open is one that has stopped asking.
    public var hasOpenDataRequest: Bool { openDataRequestCount > 0 }

    /// The queue AVFoundation calls us back on. Serial and off the main thread, per
    /// the delegate's contract.
    public let queue = DispatchQueue(label: "app.encamera.stream.resourceloader")

    public init(session: ChunkedStreamSession, contentType: String = UTType.quickTimeMovie.identifier) {
        self.session = session
        self.contentType = contentType
    }

    /// Builds a player item wired to this loader. Retain the loader for the item's
    /// lifetime — `AVURLAsset` holds its resource-loader delegate **weakly**, and a
    /// deallocated delegate is indistinguishable from a video that simply never
    /// loads.
    public func makePlayerItem() -> AVPlayerItem? {
        guard let url = EncryptedStreamScheme.url(mediaRecordName: session.mediaRecordName) else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return AVPlayerItem(asset: asset)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url,
              EncryptedStreamScheme.mediaRecordName(from: url) == session.mediaRecordName else {
            return false
        }

        let trace = beginTrace(for: loadingRequest)
        if let dataRequest = loadingRequest.dataRequest {
            let range = resolvedRange(for: dataRequest)
            let chunks = range.isEmpty ? "none" : "\(session.geometry.chunkRange(forPlaintextRange: range))"
            emit("loadingRequest received id=\(trace.id) offset=\(dataRequest.requestedOffset) "
                 + "length=\(dataRequest.requestedLength) allToEnd=\(dataRequest.requestsAllDataToEndOfResource) "
                 + "info=\(loadingRequest.contentInformationRequest != nil) chunks=\(chunks)")
        } else {
            emit("loadingRequest received id=\(trace.id) noDataRequest "
                 + "info=\(loadingRequest.contentInformationRequest != nil)")
        }

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(session.plaintextLength)
            info.isByteRangeAccessSupported = true
            info.isEntireLengthAvailableOnDemand = false
            emit("loadingRequest contentInfo id=\(trace.id) length=\(info.contentLength) "
                 + "type=\(info.contentType ?? "nil") byteRanges=\(info.isByteRangeAccessSupported)")

            // Finish on the information alone, leaving the ~2-byte dataRequest
            // AVFoundation attaches here unanswered; AVPlayer follows up with real
            // data requests.
            //
            // The widely-cited reason is a bug where answering it stops all further
            // loading requests. That does NOT reproduce on iOS 26 — answering it
            // still plays, verified by mutation-testing
            // `testRealAVPlayerBecomesReadyAndDecodesAFrameThroughTheLoader`, which
            // passes either way. Keeping the behaviour anyway: it is the documented
            // shape, it costs nothing, and the failure it guards against is silent.
            // Do not treat the test as proof that answering is unsafe.
            loadingRequest.finishLoading()
            finish(trace, for: loadingRequest)
            return true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            endTrace(for: loadingRequest)
            return false
        }

        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.serve(dataRequest: dataRequest, for: loadingRequest, trace: trace)
            self.forget(key)
        }
        remember(task, for: key)
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = tasks.removeValue(forKey: key)
        let trace = traces.removeValue(forKey: key)
        let delivered = trace?.bytes ?? 0
        lock.unlock()
        task?.cancel()
        if let trace {
            emit("loadingRequest cancelled id=\(trace.id) bytes=\(delivered) ms=\(trace.elapsedMs)")
        }
    }

    // MARK: - Tracing

    private func emit(_ line: String) {
        if let traceSink {
            traceSink(line)
        } else {
            printDebug(line)
        }
    }

    private func beginTrace(for loadingRequest: AVAssetResourceLoadingRequest) -> RequestTrace {
        lock.lock()
        defer { lock.unlock() }
        let trace = RequestTrace(id: nextRequestID,
                                 servesData: loadingRequest.contentInformationRequest == nil
                                     && loadingRequest.dataRequest != nil)
        nextRequestID += 1
        traces[ObjectIdentifier(loadingRequest)] = trace
        return trace
    }

    /// Drops the trace record; `nil` when a cancel already took it, in which case
    /// the request's outcome was reported by `didCancel`.
    @discardableResult
    private func endTrace(for loadingRequest: AVAssetResourceLoadingRequest) -> RequestTrace? {
        lock.lock()
        defer { lock.unlock() }
        return traces.removeValue(forKey: ObjectIdentifier(loadingRequest))
    }

    private func deliver(_ slice: Data, at offset: Int, to trace: RequestTrace) {
        lock.lock()
        trace.bytes += slice.count
        let total = trace.bytes
        lock.unlock()
        emit("loadingRequest slice id=\(trace.id) chunk=\(session.geometry.chunkIndex(forPlaintextOffset: offset)) "
             + "bytes=\(slice.count) total=\(total)")
    }

    private func finish(_ trace: RequestTrace, for loadingRequest: AVAssetResourceLoadingRequest) {
        guard endTrace(for: loadingRequest) != nil else { return }
        emit("loadingRequest finished id=\(trace.id) bytes=\(trace.bytes) ms=\(trace.elapsedMs)")
    }

    private func fail(_ trace: RequestTrace, for loadingRequest: AVAssetResourceLoadingRequest, range: Range<Int>, error: Error) {
        guard endTrace(for: loadingRequest) != nil else { return }
        emit("loadingRequest failed id=\(trace.id) media=\(session.mediaRecordName) range=\(range) "
             + "bytes=\(trace.bytes) ms=\(trace.elapsedMs) error=\(error)")
    }

    // MARK: - Serving

    /// Resolves what AVFoundation actually asked for into a clamped plaintext range.
    ///
    /// `internal` and pure so it can be unit-tested exhaustively:
    /// `AVAssetResourceLoadingDataRequest` has no public initializer, so the only
    /// other way to cover the off-by-one cases (a request past EOF, a request
    /// straddling it, `requestsAllDataToEndOfResource`) is to drive a real AVPlayer
    /// and hope it happens to issue them.
    static func resolvedRange(requestedOffset: Int,
                              requestedLength: Int,
                              requestsAllToEnd: Bool,
                              plaintextLength: Int) -> Range<Int> {
        // The requested window first, then intersect with the resource. Clamping the
        // START before computing the end would widen a negative-offset request past
        // the end position the caller actually asked for.
        let requestedEnd = requestsAllToEnd
            ? plaintextLength
            : requestedOffset + max(0, requestedLength)
        let start = max(0, requestedOffset)
        let end = min(plaintextLength, requestedEnd)
        guard start < end else { return 0..<0 }
        return start..<end
    }

    /// The slices `serve` hands to AVFoundation for a plaintext range, in order.
    ///
    /// A stream rather than an array on purpose: responding a chunk at a time is
    /// what lets AVPlayer decide it has enough buffered to start, instead of waiting
    /// on the whole request to complete. Exposed so a test can collect the same
    /// slices the player would receive.
    func responseSlices(for range: Range<Int>) -> AsyncThrowingStream<Data, Error> {
        let geometry = session.geometry
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = range.lowerBound
                do {
                    for chunkIndex in geometry.chunkRange(forPlaintextRange: range) {
                        try Task.checkCancellation()
                        let chunkStart = geometry.plaintextOffset(ofChunk: chunkIndex)
                        let plain = try await session.reader.plaintextChunk(at: chunkIndex)
                        let lower = max(0, cursor - chunkStart)
                        let upper = min(plain.count, range.upperBound - chunkStart)
                        guard lower < upper else { continue }
                        let slice = plain[(plain.startIndex + lower)..<(plain.startIndex + upper)]
                        continuation.yield(slice)
                        cursor += slice.count
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    private func resolvedRange(for dataRequest: AVAssetResourceLoadingDataRequest) -> Range<Int> {
        Self.resolvedRange(requestedOffset: Int(dataRequest.requestedOffset),
                           requestedLength: dataRequest.requestedLength,
                           requestsAllToEnd: dataRequest.requestsAllDataToEndOfResource,
                           plaintextLength: session.plaintextLength)
    }

    private func serve(dataRequest: AVAssetResourceLoadingDataRequest,
                       for loadingRequest: AVAssetResourceLoadingRequest,
                       trace: RequestTrace) async {
        let range = resolvedRange(for: dataRequest)
        guard !range.isEmpty else {
            loadingRequest.finishLoading()
            finish(trace, for: loadingRequest)
            return
        }

        do {
            // Slices arrive in order and each lies within one chunk, so the chunk a
            // slice came from is the one holding the cursor it starts at.
            var cursor = range.lowerBound
            for try await slice in responseSlices(for: range) {
                try Task.checkCancellation()
                dataRequest.respond(with: slice)
                deliver(slice, at: cursor, to: trace)
                cursor += slice.count
            }
            loadingRequest.finishLoading()
            finish(trace, for: loadingRequest)
        } catch is CancellationError {
            // AVFoundation already knows; touching the request after a cancel is a
            // crash, not a no-op.
        } catch {
            loadingRequest.finishLoading(with: error)
            fail(trace, for: loadingRequest, range: range, error: error)
        }
    }

    private func remember(_ task: Task<Void, Never>, for key: ObjectIdentifier) {
        lock.lock()
        tasks[key] = task
        lock.unlock()
    }

    private func forget(_ key: ObjectIdentifier) {
        lock.lock()
        tasks[key] = nil
        lock.unlock()
    }
}
