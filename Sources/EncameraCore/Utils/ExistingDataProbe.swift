//
//  ExistingDataProbe.swift
//  EncameraCore
//
//  Detects whether an account already holds Encamera data, ahead of onboarding
//  (ENC-90, under ENC-75). Detection only — no UI, no navigation, no writes.
//
//  Two requirements pull against each other and both are load-bearing:
//
//  * Data in iCloud is a HARD GATE on fresh setup. Missing existing data means a
//    returning user mints a second key and their media becomes undecryptable.
//  * A genuine new user must NEVER see a returning-user warning. It confuses them
//    and costs conversion.
//
//  So a false positive and a false negative are both real harms, and "I could not
//  tell" is a first-class answer rather than a rounding error. Every signal below
//  therefore resolves to one of three states — evidence, a trustworthy negative,
//  or unresolved — and only a trustworthy negative can produce `.none`.
//

import Foundation

// MARK: - Result types

public enum ExistingDataProbeResult: Equatable, Sendable {
    /// At least one signal returned a trustworthy negative and none found data.
    /// Proceed silently through normal onboarding.
    case none

    /// Data exists on this account. The caller must gate fresh setup on it.
    case found(ExistingDataSummary)

    /// Nothing resolved inside the time budget, or every signal was unavailable.
    /// Proceed through normal onboarding and show NO warning — a maybe is not a
    /// reason to frighten a new user.
    case unknown
}

public struct ExistingDataSummary: Equatable, Sendable {
    /// `MultiDeviceState.hasUsedEncamera` — set only after a completed onboarding
    /// or a successful auth, so it is never true for an abandoned first run.
    public var hasUsedMarker: Bool

    /// Live `EncMedia` records in the CloudKit zone. Zero with other evidence
    /// present is the local-only returning user.
    public var cloudKitMediaCount: Int

    /// Files seen in the legacy iCloud Drive container. Resolves late (see
    /// `refineWithLegacyICloudDrive`); zero until it does.
    public var iCloudDriveFileCount: Int

    /// Fingerprints of keys the existing data needs, most-used first, followed by
    /// any extra fingerprints the synced roster knows about.
    public var requiredFingerprints: [String]

    /// Devices from the synced roster. Advisory copy only — the roster merge is
    /// last-writer-merges, not a CRDT, so never make an irreversible decision
    /// from it.
    public var knownDevices: [MultiDeviceState.DeviceRecord]

    /// The user restored a prior purchase during onboarding (ENC-96). This is a
    /// BACKSTOP signal ONLY: it proves a prior *purchase*, not the presence of
    /// recoverable data — the user may have subscribed on a device whose media was
    /// purely local and has since been erased. It therefore only ever *annotates* a
    /// summary; it is NEVER read by the destructive-path gate (which keys strictly
    /// off `cloudKitMediaCount` / `iCloudDriveFileCount`), and a restore alone can
    /// never manufacture a `.found`. See `ExistingDataProbe.recordRestoredPurchase`.
    public var hasRestoredPurchase: Bool

    public init(hasUsedMarker: Bool = false,
                cloudKitMediaCount: Int = 0,
                iCloudDriveFileCount: Int = 0,
                requiredFingerprints: [String] = [],
                knownDevices: [MultiDeviceState.DeviceRecord] = [],
                hasRestoredPurchase: Bool = false) {
        self.hasUsedMarker = hasUsedMarker
        self.cloudKitMediaCount = cloudKitMediaCount
        self.iCloudDriveFileCount = iCloudDriveFileCount
        self.requiredFingerprints = requiredFingerprints
        self.knownDevices = knownDevices
        self.hasRestoredPurchase = hasRestoredPurchase
    }
}

// MARK: - Per-signal outcome

/// What one signal contributes. The distinction between `.negative` and
/// `.unresolved` is the whole correctness argument of this file: an empty answer
/// from a source that could not answer is NOT the same as an empty answer from a
/// source that answered "nothing here".
enum ProbeSignalOutcome: Equatable {
    /// The signal ran and found evidence of existing data.
    case evidence

    /// The signal ran to completion and is confident there is no data.
    case negative

    /// The signal timed out, was unavailable, or is structurally ambiguous.
    /// Contributes nothing in either direction.
    case unresolved
}

// MARK: - Probe

public actor ExistingDataProbe {

    /// Wall-clock budget for the fast signals (marker + CloudKit). Anything still
    /// outstanding when it expires is treated as absent, so onboarding is never
    /// held at a spinner. Deliberately short: the gate this feeds only matters on
    /// the tiny fraction of launches that are a returning user.
    public static let defaultBudget: TimeInterval = 3.0

    /// Separate, longer budget for the legacy iCloud Drive sweep, which is run
    /// after the branch screen is already on screen and so is allowed to be slow.
    public static let defaultLegacyBudget: TimeInterval = 8.0

    /// Set once at launch by the app so `ExistingDataProbe.shared` can read the
    /// always-synced marker without EncameraCore reaching for a concrete
    /// `KeyManager`. Mirrors `CloudKitStoreProvider.makeStore`.
    ///
    /// IMPORTANT (ENC-81): `nil` means BOTH "genuine new user" and "existing user
    /// who has not launched since the marker shipped". It is never proof of a new
    /// user, which is why `markerSignal` maps `nil` to `.unresolved`.
    nonisolated(unsafe)
    public static var multiDeviceStateProvider: @Sendable () -> MultiDeviceState? = { nil }

    /// Shared, session-scoped instance. The cache lives here so the branch screens
    /// don't re-probe on every navigation.
    public static let shared = ExistingDataProbe()

    private let budget: TimeInterval
    private let legacyBudget: TimeInterval
    private let stateProvider: @Sendable () -> MultiDeviceState?
    private let makeStore: @Sendable () -> CloudKitMediaStoring
    private let legacyFileCount: @Sendable (TimeInterval) async -> Int?

    private var cached: ExistingDataProbeResult?
    private var inFlight: Task<ExistingDataProbeResult, Never>?
    /// Bumped by `reset()`. Every async path that writes `cached` captures this
    /// first and writes only if it still matches, so a probe that was already in
    /// flight when the reset happened cannot resurrect the cache it cleared.
    ///
    /// The case this exists for is the post-erase re-probe: the destructive path
    /// runs while a probe may still be outstanding, `reset()` clears the cache, and
    /// the pre-erase probe then resumes and writes back a `.found(summary)`
    /// describing data that no longer exists — routing the user straight back into
    /// the returning-user branch they just erased their way out of.
    private var generation = 0

    /// Set by `recordRestoredPurchase()`. A backstop annotation only — see the
    /// safety contract on that method and on `ExistingDataSummary.hasRestoredPurchase`.
    private var restoredPurchase = false

    public init(budget: TimeInterval = ExistingDataProbe.defaultBudget,
                legacyBudget: TimeInterval = ExistingDataProbe.defaultLegacyBudget,
                stateProvider: (@Sendable () -> MultiDeviceState?)? = nil,
                makeStore: (@Sendable () -> CloudKitMediaStoring)? = nil,
                legacyFileCount: (@Sendable (TimeInterval) async -> Int?)? = nil) {
        self.budget = budget
        self.legacyBudget = legacyBudget
        self.stateProvider = stateProvider ?? { ExistingDataProbe.multiDeviceStateProvider() }
        self.makeStore = makeStore ?? { CloudKitStoreProvider.makeStore("existing-data-probe") }
        self.legacyFileCount = legacyFileCount ?? { budget in
            await LegacyICloudDriveSweep.fileCount(budget: budget)
        }
    }

    // MARK: Public API

    /// The fast probe: synced marker + CloudKit census, time-boxed as a whole.
    /// Cached for the session; concurrent callers share one run.
    public func result() async -> ExistingDataProbeResult {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }

        let task = Task<ExistingDataProbeResult, Never> { [budget] in
            await self.runFastSignals(budget: budget)
        }
        let startedAt = generation
        inFlight = task
        let value = await task.value
        guard startedAt == generation else { return value }
        inFlight = nil
        cached = value
        return value
    }

    /// The slow signal, run LAST and deliberately not part of `result()`: an
    /// `NSMetadataQuery` takes seconds to populate on a fresh install. The caller
    /// shows its branch screen off `result()` first, then awaits this to refine
    /// what is displayed. Can upgrade `.none`/`.unknown` to `.found`; never
    /// downgrades a `.found`.
    @discardableResult
    public func refineWithLegacyICloudDrive() async -> ExistingDataProbeResult {
        let startedAt = generation
        let base = await result()

        if let stubbed = ExistingDataProbeTestHooks.stubbedICloudDriveCount {
            return applyLegacyCount(stubbed, to: base, generation: startedAt)
        }
        guard let count = await legacyFileCount(legacyBudget) else {
            return base   // unresolved — leave the fast result exactly as it was
        }
        return applyLegacyCount(count, to: base, generation: startedAt)
    }

    /// Records a successful Restore Purchases during onboarding (ENC-96) as a
    /// BACKSTOP-ONLY signal, and returns the (possibly annotated) current result.
    ///
    /// The safety property this method exists to guarantee — and that
    /// `testRestoreAloneDoesNotTriggerDestructiveGate` pins — is that a restore
    /// ALONE is weak evidence and must NEVER, on its own, gate fresh setup or reach
    /// the destructive path. A user may have subscribed on a device whose media was
    /// purely local and since erased, so a restore is proof of a prior *purchase*,
    /// not of recoverable *data*.
    ///
    /// Concretely, this can only ever *annotate* an already-`.found` result (set by
    /// the marker / CloudKit / legacy-file signals) with `hasRestoredPurchase`; it
    /// deliberately does NOT touch a `.none` or `.unknown` cache, so it can never
    /// manufacture a `.found`. And because it only sets `hasRestoredPurchase` — never
    /// `cloudKitMediaCount` or `iCloudDriveFileCount` — it can never move the
    /// destructive-path gate, which keys strictly off those two counts.
    @discardableResult
    public func recordRestoredPurchase() -> ExistingDataProbeResult {
        restoredPurchase = true
        guard case .found(var summary) = cached else {
            // No data-bearing evidence resolved: leave `.none`/`.unknown`/nil exactly
            // as they were. A restore on its own does not create a returning user.
            return cached ?? .unknown
        }
        summary.hasRestoredPurchase = true
        cached = .found(summary)
        return cached!
    }

    /// Drops the session cache. For tests and for a post-erase re-probe.
    ///
    /// Cancels the outstanding probe AND invalidates it: cancellation alone is not
    /// enough, because `runFastSignals` is not required to observe it and would
    /// still return a value its continuation used to write straight back into the
    /// cache this just cleared.
    public func reset() {
        generation &+= 1
        inFlight?.cancel()
        cached = nil
        inFlight = nil
        restoredPurchase = false
    }

    // MARK: Fast signals

    private func runFastSignals(budget: TimeInterval) async -> ExistingDataProbeResult {
        // `-StubProbeTimeout`: every signal unresolved, so the caller can assert
        // that `.unknown` falls through to normal onboarding without a warning.
        if ExistingDataProbeTestHooks.forcesTimeout { return .unknown }

        let deadline = Date().addingTimeInterval(budget)

        // Signal 1 — the synced marker. A keychain read, effectively instant, and
        // the ONLY signal that fires for a local-only-media user.
        let state = markerState()
        let marker = Self.markerSignal(state)

        // Signal 2 — CloudKit, time-boxed. Metadata-only indexed query; it must
        // never download a blob or a thumbnail.
        let census = await withBudget(until: deadline) { [makeStore] in
            await Self.cloudKitCensus(store: makeStore())
        } ?? .unresolvedOutcome
        let cloud = census.outcome

        // `iCloudDriveFileCount` stays 0 here: signal 3 has not run yet and is
        // filled in later by `refineWithLegacyICloudDrive()`.
        //
        // The restore-purchase backstop (ENC-96) is carried on the summary but is
        // NOT passed to `combine` — only the marker and CloudKit outcomes decide
        // `.found`/`.none`/`.unknown`. This is what makes a restore incapable of, on
        // its own, producing a `.found` (and therefore incapable of gating fresh
        // setup or reaching the destructive path).
        let summary = ExistingDataSummary(
            hasUsedMarker: state?.hasUsedEncamera ?? false,
            cloudKitMediaCount: census.mediaCount,
            iCloudDriveFileCount: 0,
            requiredFingerprints: Self.orderedFingerprints(cloudKit: census.fingerprints,
                                                           marker: state?.keyFingerprints ?? []),
            knownDevices: state?.devices ?? [],
            hasRestoredPurchase: restoredPurchase
        )

        return Self.combine([marker, cloud], summary: summary)
    }

    private func markerState() -> MultiDeviceState? {
        if let stubbed = ExistingDataProbeTestHooks.stubbedMarker {
            guard stubbed else { return MultiDeviceState() }
            // Optional stubbed roster names, so the guided flip-the-switch flow
            // (ENC-93) can render its "open Encamera on your <device>" naming
            // without a real second device. Advisory copy only.
            let devices = (ExistingDataProbeTestHooks.stubbedDeviceNames ?? []).enumerated().map {
                MultiDeviceState.DeviceRecord(deviceID: "stub-device-\($0.offset)", name: $0.element, lastSeen: Date())
            }
            return MultiDeviceState(hasUsedEncamera: true, devices: devices)
        }
        return stateProvider()
    }

    /// `nil` is NOT a new user (ENC-81) — it is also every existing user who has
    /// not launched since the marker shipped, so it can only ever be `.unresolved`.
    /// A record that exists but is entirely empty is a real negative: some device
    /// wrote it and had nothing to report.
    static func markerSignal(_ state: MultiDeviceState?) -> ProbeSignalOutcome {
        guard let state else { return .unresolved }
        if state.hasUsedEncamera || !state.devices.isEmpty || !state.keyFingerprints.isEmpty {
            return .evidence
        }
        return .negative
    }

    private struct CensusReading: Sendable {
        var outcome: ProbeSignalOutcome
        var mediaCount: Int
        var fingerprints: [String: Int]

        static let unresolvedOutcome = CensusReading(outcome: .unresolved, mediaCount: 0, fingerprints: [:])
    }

    private static func cloudKitCensus(store: CloudKitMediaStoring) async -> CensusReading {
        if let stubbed = ExistingDataProbeTestHooks.stubbedCloudKitCount {
            // Optional fingerprints let a UI test drive the manual-key-entry gate
            // (ENC-92): each is given a descending count so `orderedFingerprints`
            // preserves the order they were supplied in (primary first).
            let fingerprints = ExistingDataProbeTestHooks.stubbedRequiredFingerprints ?? []
            let fingerprintMap = Dictionary(
                uniqueKeysWithValues: fingerprints.enumerated().map { ($1, fingerprints.count - $0) }
            )
            return stubbed > 0
                ? CensusReading(outcome: .evidence, mediaCount: stubbed, fingerprints: fingerprintMap)
                : CensusReading(outcome: .negative, mediaCount: 0, fingerprints: [:])
        }

        // Checked FIRST: a user not signed into iCloud otherwise hangs here.
        guard await store.accountAvailable() else { return .unresolvedOutcome }

        do {
            switch try await store.fetchFingerprintCensus() {
            case .indexUnavailable:
                // `keyFingerprint` is not queryable server-side yet (ENC-70's
                // pending Dashboard step). This tells us NOTHING — reading it as
                // "no data" is exactly the false negative that would let a
                // returning user set up as new and lose their media.
                return .unresolvedOutcome
            case .counted(let mediaCount, let fingerprints):
                return CensusReading(outcome: mediaCount > 0 ? .evidence : .negative,
                                     mediaCount: mediaCount,
                                     fingerprints: fingerprints)
            }
        } catch {
            return .unresolvedOutcome
        }
    }

    // MARK: Combination

    /// Evidence wins outright. Otherwise it takes at least one signal that
    /// actually resolved to say `.none`; all-unresolved is `.unknown`, which falls
    /// through to normal onboarding with no warning shown.
    static func combine(_ outcomes: [ProbeSignalOutcome],
                        summary: ExistingDataSummary) -> ExistingDataProbeResult {
        if outcomes.contains(.evidence) { return .found(summary) }
        if outcomes.contains(.negative) { return .none }
        return .unknown
    }

    /// CloudKit fingerprints first, ordered by descending media count (name as
    /// tiebreak so the order is deterministic), then any marker-only fingerprints.
    static func orderedFingerprints(cloudKit: [String: Int], marker: [String]) -> [String] {
        var ordered = cloudKit
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map(\.key)
        var seen = Set(ordered)
        for fingerprint in marker where seen.insert(fingerprint).inserted {
            ordered.append(fingerprint)
        }
        return ordered
    }

    /// `generation` is the value read before this refinement's awaits — the same
    /// invalidation `result()` applies, since the legacy sweep takes seconds and a
    /// `reset()` can easily land inside it.
    private func applyLegacyCount(_ count: Int,
                                  to base: ExistingDataProbeResult,
                                  generation: Int) -> ExistingDataProbeResult {
        let refined: ExistingDataProbeResult
        switch base {
        case .found(var summary):
            summary.iCloudDriveFileCount = count
            refined = .found(summary)
        case .none, .unknown:
            guard count > 0 else { return base }
            let state = markerState()
            refined = .found(ExistingDataSummary(
                hasUsedMarker: state?.hasUsedEncamera ?? false,
                cloudKitMediaCount: 0,
                iCloudDriveFileCount: count,
                requiredFingerprints: state?.keyFingerprints ?? [],
                knownDevices: state?.devices ?? []
            ))
        }
        guard generation == self.generation else { return refined }
        cached = refined
        return refined
    }

    // MARK: Time-boxing

    /// Races `work` against the deadline. `nil` means it did not finish in time —
    /// the caller treats that as an absent signal, never as a negative one.
    private func withBudget<T: Sendable>(until deadline: Date,
                                         _ work: @escaping @Sendable () async -> T) async -> T? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }

        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Legacy iCloud Drive sweep

/// Signal 3: files in the DEPRECATED iCloud Drive container, counted with an
/// `NSMetadataQuery`. Slow — seconds to populate on a fresh install — so it is
/// never on the blocking path.
enum LegacyICloudDriveSweep {

    /// Number of files under the legacy container, or `nil` when the answer could
    /// not be obtained (no ubiquity container, or the query did not finish inside
    /// `budget`). `nil` is unresolved, NOT zero.
    static func fileCount(budget: TimeInterval) async -> Int? {
        guard let root = legacyRootURL() else { return nil }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let monitor = MetadataCounter(directoryURL: root)
                let count = await monitor.count(timeout: budget)
                continuation.resume(returning: count)
            }
        }
    }

    /// `iCloudStorageModel.rootURL` deliberately NOT used: it `fatalError`s when the
    /// ubiquity container is absent, which is precisely the fresh-install-not-signed-
    /// in case this probe runs in. Same resolution order, minus the crash.
    ///
    /// The `testContainerRootOverride` branch is honoured for parity with the rest
    /// of the app, but note an override pointing at a scratch directory yields no
    /// `NSMetadataQuery` results (the ubiquitous scope only sees a real container),
    /// so simulator UI tests drive this signal through
    /// `ExistingDataProbeTestHooks.stubbedICloudDriveCount` instead.
    static func legacyRootURL() -> URL? {
        if let override = iCloudStorageModel.testContainerRootOverride {
            return override
        }
        return FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents")
    }
}

/// One-shot `NSMetadataQuery` that reports how many items it gathered, then stops.
/// Modelled on `iCloudDirectoryMonitor`, but terminating instead of observing.
@MainActor
private final class MetadataCounter {
    private let directoryURL: URL
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Int?, Never>?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func count(timeout: TimeInterval) async -> Int? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(format: "%K BEGINSWITH %@",
                                          NSMetadataItemPathKey, directoryURL.path)
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(with: query.resultCount) }
            }
            self.query = query
            query.start()

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(with: nil)   // timed out: unresolved, not zero
            }
        }
    }

    private func finish(with value: Int?) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        query?.stop()
        query = nil
        continuation.resume(returning: value)
    }
}

// MARK: - Test hooks

/// UI-test-only stubs, one per signal, so the returning-user branch screens
/// (ENC-91..96) can be driven in a simulator that has no iCloud account. All
/// default to inert; the app sets them from launch arguments inside
/// `UITestMode.setupIfNeeded()`, so production builds are unaffected.
public enum ExistingDataProbeTestHooks {
    /// `-StubProbeMarker=true|false`. Replaces the synced-marker read. `nil` (the
    /// default) reads the real record — including its `nil`-is-unknown semantics.
    nonisolated(unsafe) public static var stubbedMarker: Bool?

    /// `-StubProbeCloudKitCount=N`. Replaces the CloudKit census entirely, so no
    /// account check and no query happen. `0` stubs a trustworthy negative.
    nonisolated(unsafe) public static var stubbedCloudKitCount: Int?

    /// `-StubProbeICloudDriveCount=N`. Replaces the legacy iCloud Drive sweep,
    /// which a simulator cannot otherwise produce results for.
    nonisolated(unsafe) public static var stubbedICloudDriveCount: Int?

    /// The fingerprints the stubbed CloudKit census reports as required, so the
    /// manual-key-entry gate (ENC-92) can be driven in a simulator. Ordered
    /// primary-first. Only consulted when `stubbedCloudKitCount` is set.
    nonisolated(unsafe) public static var stubbedRequiredFingerprints: [String]?

    /// Device names to seed into the stubbed marker's roster (ENC-93), so the
    /// guided flip-the-switch flow can render "open Encamera on your <device>"
    /// without a real second device. Only consulted when `stubbedMarker == true`.
    nonisolated(unsafe) public static var stubbedDeviceNames: [String]?

    /// `-StubProbeTimeout`. Forces every signal to be unresolved, so a test can
    /// assert that `.unknown` falls through to normal onboarding with no warning.
    nonisolated(unsafe) public static var forcesTimeout: Bool = false

    public static func reset() {
        stubbedMarker = nil
        stubbedCloudKitCount = nil
        stubbedICloudDriveCount = nil
        stubbedRequiredFingerprints = nil
        stubbedDeviceNames = nil
        forcesTimeout = false
    }
}
