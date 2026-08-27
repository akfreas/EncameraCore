//
//  ICloudDriveMaterializer.swift
//  EncameraCore
//
//  Brings evicted iCloud Drive files back onto local disk so the CloudKit
//  migration engine can treat them exactly as it treats local files.
//
//  An iCloud Drive album a user has not opened in a while is mostly *placeholders*:
//  a `.<id>.<ext>.icloud` brick standing in for a file whose bytes live only in
//  Apple's cloud. `CKAsset(fileURL:)` cannot upload a brick, and `attributesOfItem`
//  on one reports a few hundred bytes rather than the photo's real size. So before
//  the engine can migrate such an album it has to materialize the files — and it
//  has to do so a batch at a time, or moving a 40 GB album would first demand 40 GB
//  of free space on the phone.
//
//  Everything here is built on machinery the app already had:
//  `iCloudFileStatusUtil.startDownload(for:)` to request a download, and the
//  NSMetadataQuery configuration + twin-notification observation pattern from
//  `iCloudDirectoryMonitor` and `iCloudStorageModel.monitorDownloadProgress`.
//  What is new is that this one is *awaitable per batch* and has a deadline:
//  `downloadFileFromiCloud` never times out, which is tolerable for one photo a
//  user is staring at and unacceptable for an unattended migration batch.
//

import Foundation

// MARK: - Protocol

/// Materializes evicted iCloud Drive files. A protocol so the migration engine can
/// be unit-tested off-device: neither a simulator nor a test host has a ubiquity
/// container, so the real implementation can never actually download anything there.
@MainActor
public protocol ICloudDriveMaterializing: AnyObject {

    /// The real byte size of every file in `directory`, keyed by *materialized*
    /// filename (`<id>.<ext>`, never the `.icloud` brick name).
    ///
    /// Read from `NSMetadataItemFSSizeKey`, which reports an evicted file's true
    /// size — `FileManager.attributesOfItem` on the placeholder reports the
    /// placeholder's. The migration plan needs the true size for three things: an
    /// honest byte total in the confirmation alert, meaningful byte-weighted
    /// progress, and the CloudKit verification gate, which refuses to delete a
    /// source unless the uploaded record's size matches the planned size.
    func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64]

    /// Downloads a batch and resolves once every URL has either materialized or
    /// failed. Concurrent within the batch; bounded by a deadline so one stuck file
    /// cannot wedge a migration forever.
    ///
    /// Keys of the returned dictionary are the *materialized* URLs passed in.
    func materialize(_ urls: [URL],
                     inAlbumDirectory directory: URL,
                     onProgress: @escaping (Double) -> Void) async -> [URL: Result<URL, Error>]

    /// Pushes materialized bytes back out to iCloud, freeing the disk they occupy.
    /// Used when a migration is paused or cancelled mid-batch: without it, stopping
    /// a move would leave behind exactly the pile of downloaded files that batching
    /// exists to prevent. Eviction is not deletion — the file stays in iCloud Drive.
    ///
    /// - Returns: the URLs whose bytes were actually given back. Best effort is not
    ///   the same as done: iCloud refuses to evict an item it considers busy, so a
    ///   caller that wants to report how much space came back must count what this
    ///   returns rather than what it was asked to do.
    @discardableResult
    func evict(_ urls: [URL]) -> [URL]
}

// MARK: - Batch size

/// How many evicted files the migration materializes at a time.
///
/// The whole point of batching is that peak extra disk stays at roughly one batch
/// rather than one album: the engine deletes each source once CloudKit has verified
/// it, so batch *k+1* downloads into the space batch *k* just freed. Too small and
/// the migration spends its life waiting on round trips; too large and a big album
/// fills the phone. The right number is empirical, so it is a runtime setting rather
/// than a constant — see `ICloudDriveMigrationDeviceTests`, which measures it.
public enum ICloudDriveMigrationBatchSize {

    public static let `default` = 10
    public static let range = 1...100

    /// The configured size, clamped. An unset (`0`) default means "use the default".
    public static var current: Int {
        get {
            let stored = UserDefaultUtils.integer(forKey: .iCloudDriveMigrationBatchSize)
            guard stored != 0 else { return `default` }
            return min(max(stored, range.lowerBound), range.upperBound)
        }
        set {
            UserDefaultUtils.set(min(max(newValue, range.lowerBound), range.upperBound),
                                 forKey: .iCloudDriveMigrationBatchSize)
        }
    }
}

// MARK: - Observability

/// Every counter the on-device suite reads, in the order the marker publishes
/// them.
///
/// One struct rather than eight properties on the observer so the list is
/// written down ONCE. `reset()` is `counters = .init()`, which cannot miss a
/// member, and `markerLabel` is generated from these same declarations, so a
/// ninth counter is reset and published by adding it here and nothing else.
///
/// The property names ARE the marker's field names; the device tests look every
/// field up by name (`AlbumDetailScreen.materializationCounter`), so renaming one
/// renames the wire format.
public struct MaterializationCounters: Equatable {

    /// Download batches requested.
    public var batches = 0
    /// The largest batch requested, for the "batches never exceed N" bound.
    public var maxBatch = 0
    /// The most source files found already on disk at the start of any batch. If
    /// batching works this stays at 0 — each batch's files are uploaded, verified
    /// and deleted before the next batch is requested. A number that climbs with
    /// the album size means the bound is broken.
    public var peakOnDisk = 0
    /// Files whose bytes were actually pushed back out to iCloud when a run was
    /// paused or cancelled — counted from what `evict` reports it succeeded on,
    /// after the fact. Not what the engine intended to evict.
    public var evicted = 0
    /// How many of those files had their bytes on disk at the moment the run
    /// stopped. `evicted == onDiskAtStop` is "the user got the space back"; a zero
    /// here means nothing had been downloaded, so an eviction counter of zero says
    /// nothing either way.
    public var onDiskAtStop = 0
    /// Of the files `evict` accepted, how many are confirmed to have lost their
    /// bytes — re-read from iCloud's own download status afterwards rather than
    /// inferred from a call that did not throw.
    public var evictedVerified = 0
    /// Batches that finished because iCloud reported every file downloaded.
    public var observedBatches = 0
    /// Batches that only ended when the per-batch deadline expired. The files may
    /// well have arrived anyway, so nothing downstream notices — which is exactly
    /// why this is counted: a migration running on the deadline instead of on the
    /// `NSMetadataQuery` notifications is a broken observation wearing a working
    /// migration's clothes.
    public var deadlineBatches = 0

    public init() {}

    /// `batches=3:maxBatch=10:...`, the payload of the app's
    /// `iCloudDriveMaterialization` marker.
    ///
    /// Reflected off the stored properties rather than concatenated by hand, so
    /// the field list cannot drift from the declarations above. Order follows
    /// declaration order; every reader looks fields up by name, so it is not
    /// load-bearing.
    public var markerLabel: String {
        Mirror(reflecting: self).children
            .compactMap { child in child.label.map { "\($0)=\(child.value)" } }
            .joined(separator: ":")
    }
}

/// Counters the on-device tests assert against.
///
/// The claims this feature makes — "batches never exceed N", "batch k+1 does not
/// start until batch k's files are gone", "stopping mid-batch gives the space back"
/// — are all invisible from the UI. Sampling free disk from a test process is far
/// too noisy on a real phone (other processes churn it constantly), so the engine
/// reports what it actually did instead. Inert unless switched on.
@MainActor
public final class ICloudDriveMigrationObserver: ObservableObject {

    public static let shared = ICloudDriveMigrationObserver()
    private init() {}

    /// Off in production. The app turns it on under UI-test mode only.
    public var isEnabled = false

    @Published public private(set) var counters = MaterializationCounters()

    public func reset() {
        counters = .init()
    }

    func recordBatch(size: Int, alreadyMaterialized: Int) {
        guard isEnabled else { return }
        counters.batches += 1
        counters.maxBatch = max(counters.maxBatch, size)
        counters.peakOnDisk = max(counters.peakOnDisk, alreadyMaterialized)
    }

    func recordBatchResolved(byDeadline: Bool) {
        guard isEnabled else { return }
        if byDeadline {
            counters.deadlineBatches += 1
        } else {
            counters.observedBatches += 1
        }
    }

    func recordEviction(evicted: Int, materializedAtStop: Int) {
        guard isEnabled else { return }
        counters.evicted += evicted
        counters.onDiskAtStop += materializedAtStop
    }

    /// Re-reads, off the stop path, how many of the evicted files really gave their
    /// bytes back.
    ///
    /// `evictUbiquitousItem` returning without throwing is not the same as the space
    /// being back: it is asynchronous, and a file iCloud considers busy simply stays
    /// put — the seeder that manufactures this suite's fixtures had to learn the same
    /// thing. So the number a test asserts on is read from iCloud's download status
    /// afterwards, not from the API's silence. Inert unless the observer is switched
    /// on, so a shipped build never runs the poll.
    ///
    /// Each call contributes only its OWN progress: it tracks what it has already
    /// credited and adds the difference. Reading a base outside the task instead
    /// would let two overlapping calls both compute from the same starting value,
    /// and the second would overwrite the first's contribution.
    func confirmEviction(of urls: [URL]) {
        guard isEnabled, !urls.isEmpty else { return }
        Task { @MainActor in
            var credited = 0
            for _ in 0..<40 {
                let remaining = urls.filter { ICloudPlaceholderName.isMaterialized($0) }
                let confirmed = urls.count - remaining.count
                counters.evictedVerified += confirmed - credited
                credited = confirmed
                if remaining.isEmpty { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}

// MARK: - Errors

public enum ICloudMaterializationError: Error, LocalizedError, Equatable {
    /// The file did not finish downloading before the batch deadline.
    case timedOut(filename: String)
    /// iCloud reported a download error for this item.
    case downloadFailed(filename: String, message: String)
    /// The download could not even be requested.
    case couldNotStartDownload(filename: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let filename):
            return "\(filename) did not finish downloading from iCloud Drive in time"
        case .downloadFailed(let filename, let message):
            return "\(filename) could not be downloaded from iCloud Drive: \(message)"
        case .couldNotStartDownload(let filename, let message):
            return "Could not start downloading \(filename) from iCloud Drive: \(message)"
        }
    }
}

// MARK: - Filename normalization

public enum ICloudPlaceholderName {

    /// The materialized filename behind a placeholder brick: `.abc.encimage.icloud`
    /// -> `abc.encimage`. Idempotent, so it is safe to run over a mixed listing of
    /// materialized files and bricks.
    ///
    /// Mirrors `MediaDescribing.downloadedSource`, but works on a bare filename so
    /// it can also normalize the names NSMetadataQuery reports (which may be either
    /// form depending on the item's state).
    public static func materializedFilename(from filename: String) -> String {
        var name = filename
        if name.hasPrefix(".") { name.removeFirst() }
        if name.hasSuffix(".icloud") { name.removeLast(".icloud".count) }
        return name
    }

    /// The placeholder brick URL for a materialized URL, i.e. where the file lives
    /// on disk while it is still evicted.
    public static func placeholderURL(forMaterialized url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// Whether the file exists in *either* form. A migration must be able to tell
    /// "this file is gone" (terminally skippable) from "this file is still only a
    /// placeholder" (a download failure, retryable) — conflating them strands data.
    public static func existsInAnyForm(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path)
            || fileManager.fileExists(atPath: placeholderURL(forMaterialized: url).path)
    }

    /// Whether the file's BYTES are actually on this device.
    ///
    /// `FileManager.fileExists` is emphatically not this question for a ubiquitous
    /// item. On iOS an evicted file keeps its path and answers `true` while its
    /// contents live only in iCloud — the visible `.<name>.icloud` brick is a Finder
    /// convention, not something you can count on here. Handing such a URL to
    /// `CKAsset(fileURL:)` uploads a placeholder, which CloudKit rejects with a
    /// retryable error; nine identical failures on the rig is exactly how this was
    /// found. Ask iCloud for the download status instead.
    public static func isMaterialized(_ url: URL) -> Bool {
        if let override = testEvictedURLs, override.contains(url.standardizedFileURL) { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // `needsDownload` is false for a non-ubiquitous file, so a local album's
        // files are always "materialized" and take no special path.
        return !iCloudFileStatusUtil.needsDownload(url: url)
    }

    /// Test seam: URLs to treat as evicted even though the file is present.
    ///
    /// Without this, no off-device test can reproduce the shape that actually broke
    /// on the rig — a file whose path resolves while its bytes live in iCloud —
    /// because a scratch directory has no ubiquity status to report. A fake that
    /// models eviction by *deleting* the file tests a state iOS never produces, and
    /// would have gone on passing through the placeholder-upload bug. Nil in
    /// production.
    nonisolated(unsafe) public static var testEvictedURLs: Set<URL>?
}

// MARK: - Implementation

@MainActor
public final class ICloudDriveMaterializer: ICloudDriveMaterializing, DebugPrintable {

    /// Deadline for a whole batch. Matches `DiskFileAccess.waitForICloudDownload`'s
    /// existing 300 s cap, so a migration is no less patient than a user tapping a
    /// single photo. A batch that only ever completes by hitting this is a bug in
    /// the observation, not a slow network — see the device tests.
    public static let defaultBatchTimeout: TimeInterval = 300

    /// Deadline for the initial metadata gather when sizing an album. Much shorter:
    /// nothing is being transferred, we are only waiting for the local metadata
    /// index to answer.
    public static let defaultGatherTimeout: TimeInterval = 30

    private let batchTimeout: TimeInterval
    private let gatherTimeout: TimeInterval

    public init(batchTimeout: TimeInterval = ICloudDriveMaterializer.defaultBatchTimeout,
                gatherTimeout: TimeInterval = ICloudDriveMaterializer.defaultGatherTimeout) {
        self.batchTimeout = batchTimeout
        self.gatherTimeout = gatherTimeout
    }

    /// Whether iCloud Drive is actually reachable. An `NSMetadataQuery` scoped to
    /// `NSMetadataQueryUbiquitousDocumentsScope` never reports anything on a device
    /// with no ubiquity container — it does not fail, it simply stays silent, so
    /// every call would sit until its deadline. Answering up front turns a 300 s
    /// hang into an immediate, honest failure.
    private static var isICloudDriveReachable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    // MARK: Sizing

    public func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64] {
        guard Self.isICloudDriveReachable else {
            printDebug("logicalSizes skipped — no ubiquity container on this device")
            return [:]
        }
        let query = Self.makeQuery(for: directory, attributes: [
            NSMetadataItemFSSizeKey,
            NSMetadataUbiquitousItemDownloadingStatusKey
        ])

        let items = await gatherOnce(query: query)
        var sizes: [String: Int64] = [:]
        for item in items {
            guard let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
                  let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber else { continue }
            sizes[ICloudPlaceholderName.materializedFilename(from: name)] = size.int64Value
        }
        printDebug("logicalSizes gathered \(sizes.count) file size(s) for \(directory.lastPathComponent)")
        return sizes
    }

    // MARK: Materializing

    public func materialize(_ urls: [URL],
                            inAlbumDirectory directory: URL,
                            onProgress: @escaping (Double) -> Void) async -> [URL: Result<URL, Error>] {
        var results: [URL: Result<URL, Error>] = [:]
        var pending: [String: URL] = [:]   // materialized filename -> materialized URL

        for url in urls {
            if ICloudPlaceholderName.isMaterialized(url) {
                // Bytes already here — a resumed run, or a file that was never
                // evicted. Note this is NOT `fileExists`: an evicted file's path
                // still resolves, and treating that as "already downloaded" is how
                // a placeholder ends up in CloudKit.
                results[url] = .success(url)
                continue
            }
            pending[url.lastPathComponent] = url
        }

        guard !pending.isEmpty else {
            onProgress(1)
            return results
        }

        guard Self.isICloudDriveReachable else {
            // Fail every pending file rather than waiting out the deadline. The
            // engine turns these into retryable `.failed` items, so the album stays
            // whole and finishes once iCloud is signed in again.
            for (name, url) in pending {
                results[url] = .failure(ICloudMaterializationError.downloadFailed(
                    filename: name, message: "iCloud Drive is not available on this device"))
            }
            return results
        }

        // Request every download up front so they proceed concurrently; the query
        // below is only an observer, it does not drive the transfers.
        for (_, url) in pending {
            do {
                try Self.requestDownload(of: url)
            } catch {
                results[url] = .failure(ICloudMaterializationError.couldNotStartDownload(
                    filename: url.lastPathComponent, message: "\(error)"))
            }
        }
        for (name, url) in pending where results[url] != nil { pending[name] = nil }
        guard !pending.isEmpty else { return results }

        printDebug("materialize batch of \(pending.count) file(s) in \(directory.lastPathComponent)")
        let observed = await observeDownloads(of: pending, in: directory, onProgress: onProgress)
        return results.merging(observed) { _, new in new }
    }

    @discardableResult
    public func evict(_ urls: [URL]) -> [URL] {
        // `isMaterialized`, not `fileExists`: an evicted file's path still resolves,
        // so `fileExists` would have this ask iCloud to evict placeholders it has
        // already evicted — and count them as space given back.
        let fileManager = FileManager.default
        var evicted: [URL] = []
        for url in urls where ICloudPlaceholderName.isMaterialized(url) {
            do {
                try fileManager.evictUbiquitousItem(at: url)
                evicted.append(url)
            } catch {
                // Best effort: failing to reclaim space is not a reason to fail a
                // pause or cancel the user asked for.
                printDebug("evict FAILED \(url.lastPathComponent) error=\(error)")
            }
        }
        return evicted
    }

    // MARK: - Query plumbing

    private static func makeQuery(for directory: URL, attributes: [String]) -> NSMetadataQuery {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // A directory predicate, not the per-file `NSMetadataItemURLKey ==` form used
        // by `iCloudStorageModel.monitorDownloadProgress`: a placeholder and its
        // materialized twin have different paths, so matching one exact URL misses
        // the item in whichever state we didn't guess. Matching the directory and
        // normalizing names afterwards is immune to that.
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, directory.path)
        query.valueListAttributes = attributes
        return query
    }

    /// `startDownloadingUbiquitousItem` wants the item's URL; for an evicted file
    /// the documented form is the materialized URL, but the brick path is what
    /// enumeration hands us elsewhere in the app. Try the documented form and fall
    /// back, so neither convention can silently no-op.
    private static func requestDownload(of materializedURL: URL) throws {
        do {
            try iCloudFileStatusUtil.startDownload(for: materializedURL)
        } catch {
            let placeholder = ICloudPlaceholderName.placeholderURL(forMaterialized: materializedURL)
            guard FileManager.default.fileExists(atPath: placeholder.path) else { throw error }
            try iCloudFileStatusUtil.startDownload(for: placeholder)
        }
    }

    /// Runs a query until its first gathering pass completes (or the gather deadline
    /// elapses) and returns the results.
    private func gatherOnce(query: NSMetadataQuery) async -> [NSMetadataItem] {
        await withCheckedContinuation { continuation in
            let state = QueryRun(query: query)
            var observer: NSObjectProtocol?

            let finish: @MainActor () -> Void = {
                guard state.claim() else { return }
                query.disableUpdates()
                let items = query.results as? [NSMetadataItem] ?? []
                query.enableUpdates()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                query.stop()
                continuation.resume(returning: items)
            }

            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { _ in MainActor.assumeIsolated { finish() } }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(self.gatherTimeout * 1_000_000_000))
                finish()
            }

            query.start()
        }
    }

    /// The core observation loop: one query over the album directory, both
    /// notifications, resolving each pending file the moment iCloud reports it
    /// downloaded (or the moment its bytes appear on disk, whichever lands first).
    private func observeDownloads(of pending: [String: URL],
                                  in directory: URL,
                                  onProgress: @escaping (Double) -> Void) async -> [URL: Result<URL, Error>] {
        let query = Self.makeQuery(for: directory, attributes: [
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemPercentDownloadedKey,
            NSMetadataUbiquitousItemIsDownloadingKey,
            NSMetadataUbiquitousItemDownloadingErrorKey
        ])

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let state = QueryRun(query: query)
                var observers: [NSObjectProtocol] = []
                var outstanding = pending
                var results: [URL: Result<URL, Error>] = [:]
                var percentByName: [String: Double] = [:]
                let totalCount = Double(pending.count)

                let teardown: @MainActor () -> Void = {
                    observers.forEach { NotificationCenter.default.removeObserver($0) }
                    observers.removeAll()
                    query.stop()
                }

                /// Resolve everything still outstanding as a timeout and finish.
                let finishByDeadline: @MainActor () -> Void = {
                    guard state.claim() else { return }
                    ICloudDriveMigrationObserver.shared.recordBatchResolved(byDeadline: true)
                    for (name, url) in outstanding {
                        results[url] = .failure(ICloudMaterializationError.timedOut(filename: name))
                    }
                    teardown()
                    continuation.resume(returning: results)
                }

                let processResults: @MainActor () -> Void = {
                    guard !state.isClaimed else { return }
                    query.disableUpdates()
                    let items = query.results as? [NSMetadataItem] ?? []
                    query.enableUpdates()

                    for item in items {
                        guard let rawName = item.value(forAttribute: NSMetadataItemFSNameKey) as? String
                        else { continue }
                        let name = ICloudPlaceholderName.materializedFilename(from: rawName)
                        guard let url = outstanding[name] else { continue }

                        let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
                        let downloadError = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingErrorKey) as? NSError

                        if let downloadError {
                            outstanding[name] = nil
                            percentByName[name] = 0
                            results[url] = .failure(ICloudMaterializationError.downloadFailed(
                                filename: name, message: downloadError.localizedDescription))
                            continue
                        }

                        let reportedDownloaded = status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                            || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded
                        // Require BOTH the metadata's word and the file's own
                        // download status: the metadata attribute is known to lag,
                        // and an evicted file's path resolves either way, so neither
                        // signal alone is enough to call the bytes present.
                        if reportedDownloaded, ICloudPlaceholderName.isMaterialized(url) {
                            outstanding[name] = nil
                            percentByName[name] = 100
                            results[url] = .success(url)
                            continue
                        }

                        if let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
                            percentByName[name] = percent
                        }
                    }

                    let done = Double(results.count) * 100
                    let inFlight = percentByName.filter { outstanding[$0.key] != nil }.values.reduce(0, +)
                    onProgress(totalCount > 0 ? min(1, (done + inFlight) / (totalCount * 100)) : 1)

                    if outstanding.isEmpty, state.claim() {
                        ICloudDriveMigrationObserver.shared.recordBatchResolved(byDeadline: false)
                        teardown()
                        continuation.resume(returning: results)
                    }
                }

                // Both notifications, exactly as the existing download observation does:
                // completion genuinely does not always arrive in the update payload, and
                // an already-downloaded file only ever shows up in the gather.
                for name in [Notification.Name.NSMetadataQueryDidFinishGathering,
                             Notification.Name.NSMetadataQueryDidUpdate] {
                    observers.append(NotificationCenter.default.addObserver(
                        forName: name, object: query, queue: .main
                    ) { _ in MainActor.assumeIsolated { processResults() } })
                }

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(self.batchTimeout * 1_000_000_000))
                    finishByDeadline()
                }

                query.start()
            }
        } onCancel: {
            Task { @MainActor in query.stop() }
        }
    }

    /// One-shot guard so a continuation is resumed exactly once no matter which of
    /// the notification, the filesystem check or the deadline gets there first.
    @MainActor
    private final class QueryRun {
        private(set) var isClaimed = false
        private let query: NSMetadataQuery

        init(query: NSMetadataQuery) { self.query = query }

        func claim() -> Bool {
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }
}
