//
//  ExistingDataProbeTests.swift
//  EncameraCoreTests
//
//  ENC-90. The probe has two failure modes that are both real harms — warning a
//  genuine new user, and failing to warn a returning one — so these tests pin the
//  three-state resolution rather than just the happy path.
//

import XCTest
@testable import EncameraCore

final class ExistingDataProbeTests: XCTestCase {

    private var savedMakeStore: (@Sendable (String) -> CloudKitMediaStoring)!

    override func setUp() {
        super.setUp()
        savedMakeStore = CloudKitStoreProvider.makeStore
        ExistingDataProbeTestHooks.reset()
    }

    override func tearDown() {
        CloudKitStoreProvider.makeStore = savedMakeStore
        ExistingDataProbeTestHooks.reset()
        super.tearDown()
    }

    // MARK: Helpers

    private func makeProbe(marker: MultiDeviceState?,
                           store: CloudKitMediaStoring,
                           budget: TimeInterval = 2.0,
                           legacyCount: Int? = nil) -> ExistingDataProbe {
        ExistingDataProbe(budget: budget,
                          legacyBudget: budget,
                          stateProvider: { marker },
                          makeStore: { store },
                          legacyFileCount: { _ in legacyCount })
    }

    private func upload(fingerprint: String, id: String) -> CloudKitMediaUpload {
        CloudKitMediaUpload(albumID: "album",
                            mediaID: id,
                            mediaType: .photo,
                            createdAt: Date(),
                            sizeBytes: 10,
                            encryptedFileURL: URL(fileURLWithPath: "/dev/null"),
                            encryptedThumbURL: nil,
                            keyFingerprint: fingerprint)
    }

    private func seed(_ store: MockCloudKitMediaStore, _ items: [CloudKitMediaUpload]) async throws {
        for item in items {
            _ = try await store.upload(item, progress: { _ in })
        }
    }

    // MARK: - Acceptance cases

    /// A genuine new user, signed into iCloud with an empty zone: every signal that
    /// can answer answers "nothing", so the probe resolves `.none` and onboarding
    /// shows no returning-user UI at all.
    func testNoSignalsReturnsNone() async {
        let store = MockCloudKitMediaStore()
        let probe = makeProbe(marker: nil, store: store)

        let result = await probe.result()

        XCTAssertEqual(result, ExistingDataProbeResult.none)
    }

    /// The local-only returning user. No CloudKit media at all, but the always-synced
    /// marker fires — it is the ONLY signal that can detect them, and missing it
    /// would let them mint a second key and lose their media.
    func testMarkerOnlyReturnsFoundWithZeroCounts() async {
        let store = MockCloudKitMediaStore()
        let device = MultiDeviceState.DeviceRecord(deviceID: "dev-1", name: "iPhone", lastSeen: Date())
        let marker = MultiDeviceState(hasUsedEncamera: true,
                                      devices: [device],
                                      keyFingerprints: ["aabb"])
        let probe = makeProbe(marker: marker, store: store)

        guard case .found(let summary) = await probe.result() else {
            return XCTFail("expected .found from the synced marker alone")
        }
        XCTAssertTrue(summary.hasUsedMarker)
        XCTAssertEqual(summary.cloudKitMediaCount, 0)
        XCTAssertEqual(summary.iCloudDriveFileCount, 0)
        XCTAssertEqual(summary.requiredFingerprints, ["aabb"])
        XCTAssertEqual(summary.knownDevices.map(\.deviceID), ["dev-1"])
    }

    func testCloudKitRecordsReturnCountsAndFingerprints() async throws {
        let store = MockCloudKitMediaStore()
        try await seed(store, [upload(fingerprint: "ffff", id: "a"),
                               upload(fingerprint: "ffff", id: "b"),
                               upload(fingerprint: "1111", id: "c")])
        let probe = makeProbe(marker: nil, store: store)

        guard case .found(let summary) = await probe.result() else {
            return XCTFail("expected .found from CloudKit records")
        }
        XCTAssertEqual(summary.cloudKitMediaCount, 3)
        // Most-used fingerprint first, so the branch screen can lead with it.
        XCTAssertEqual(summary.requiredFingerprints, ["ffff", "1111"])
        XCTAssertFalse(summary.hasUsedMarker)
    }

    /// A signal that cannot answer inside the budget is absent, not negative. With
    /// the marker also unknown nothing resolves, so the answer is `.unknown` — which
    /// falls through to normal onboarding WITHOUT a warning.
    func testSlowSignalTimesOutToUnknown() async throws {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusDelayNanos = 5_000_000_000
        try await seed(store, [upload(fingerprint: "ffff", id: "a")])
        let probe = makeProbe(marker: nil, store: store, budget: 0.3)

        let started = Date()
        let result = await probe.result()

        XCTAssertEqual(result, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0,
                          "the probe must not exceed its time budget")
    }

    /// The indexed query is the whole reason this is cheap: no blob, no thumbnail.
    func testProbeDownloadsNoBlobs() async throws {
        let store = MockCloudKitMediaStore()
        try await seed(store, [upload(fingerprint: "ffff", id: "a"),
                               upload(fingerprint: "ffff", id: "b")])
        let probe = makeProbe(marker: nil, store: store)

        _ = await probe.result()

        XCTAssertEqual(store.fetchBlobCount, 0)
        XCTAssertEqual(store.fetchThumbnailCount, 0)
        XCTAssertGreaterThan(store.fingerprintCensusCount, 0, "the probe must actually have queried")
    }

    /// No iCloud account: resolve quickly and never hang. CloudKit contributes
    /// nothing, and with the marker also nil the honest answer is `.unknown`.
    func testUnavailableAccountDoesNotHang() async {
        let store = MockCloudKitMediaStore()
        store.accountAvailableValue = false
        let probe = makeProbe(marker: nil, store: store, budget: 2.0)

        let started = Date()
        let result = await probe.result()

        XCTAssertEqual(result, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(store.fingerprintCensusCount, 0, "must not query without an account")
    }

    // MARK: - The two ways to read an empty answer

    /// THE false negative this ticket exists to prevent. `keyFingerprint` is not
    /// queryable server-side yet (ENC-70's pending Dashboard step), so the query
    /// returns nothing — that is "could not tell", never "no data exists". Reading
    /// it as `.none` would let a returning user set up as new and lose their media.
    func testUnavailableIndexIsUnknownNotNone() async {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .indexUnavailable
        let probe = makeProbe(marker: nil, store: store)

        let probed = await probe.result()
        XCTAssertEqual(probed, .unknown)
    }

    /// The mirror image: an empty zone that genuinely answered is a trustworthy
    /// negative, and must NOT degrade into `.unknown` — a new user gets the silent
    /// path, not a maybe.
    func testGenuinelyEmptyZoneIsNoneNotUnknown() async {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .counted(mediaCount: 0, fingerprints: [:])
        let probe = makeProbe(marker: nil, store: store)

        let probed = await probe.result()
        XCTAssertEqual(probed, ExistingDataProbeResult.none)
    }

    /// Records exist but predate the fingerprint field, so no fingerprint is
    /// counted. Data still exists — the count, not the fingerprint map, is what
    /// answers "is there anything here".
    func testRecordsWithoutFingerprintsStillCountAsData() async {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .counted(mediaCount: 4, fingerprints: [:])
        let probe = makeProbe(marker: nil, store: store)

        guard case .found(let summary) = await probe.result() else {
            return XCTFail("pre-fingerprint records are still existing data")
        }
        XCTAssertEqual(summary.cloudKitMediaCount, 4)
        XCTAssertTrue(summary.requiredFingerprints.isEmpty)
    }

    /// A thrown error is unresolved too, never a negative.
    func testCensusErrorIsUnknown() async {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusError = NSError(domain: "test", code: 1)
        let probe = makeProbe(marker: nil, store: store)

        let probed = await probe.result()
        XCTAssertEqual(probed, .unknown)
    }

    // MARK: - Marker semantics (ENC-81)

    /// `getMultiDeviceState()` returns nil for BOTH a genuine new user and an
    /// existing user who has not launched since the marker shipped. So nil alone
    /// can never decide anything: here CloudKit is unavailable too, and the result
    /// must be `.unknown` rather than `.none`.
    func testNilMarkerIsUnknownNotNew() {
        XCTAssertEqual(ExistingDataProbe.markerSignal(nil), .unresolved)
    }

    /// A record that exists but is empty was written by some device that had
    /// nothing to report — that IS a trustworthy negative.
    func testEmptyMarkerRecordIsNegative() {
        XCTAssertEqual(ExistingDataProbe.markerSignal(MultiDeviceState()), .negative)
    }

    /// `hasUsedEncamera` is not the only evidence: a roster entry or a known
    /// fingerprint proves the account has been used.
    func testMarkerWithRosterOnlyIsEvidence() {
        let device = MultiDeviceState.DeviceRecord(deviceID: "d", name: "iPhone", lastSeen: Date())
        XCTAssertEqual(ExistingDataProbe.markerSignal(MultiDeviceState(devices: [device])), .evidence)
        XCTAssertEqual(ExistingDataProbe.markerSignal(MultiDeviceState(keyFingerprints: ["ab"])), .evidence)
    }

    /// A returning marker plus an unavailable CloudKit index still warns: evidence
    /// from any one signal wins outright.
    func testEvidenceWinsOverUnresolvedSignal() async {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .indexUnavailable
        let probe = makeProbe(marker: MultiDeviceState(hasUsedEncamera: true), store: store)

        guard case .found = await probe.result() else {
            return XCTFail("marker evidence must survive an unresolved CloudKit signal")
        }
    }

    // MARK: - Combination rules

    func testCombineRules() {
        let summary = ExistingDataSummary()
        XCTAssertEqual(ExistingDataProbe.combine([.unresolved, .unresolved], summary: summary), .unknown)
        XCTAssertEqual(ExistingDataProbe.combine([.unresolved, .negative], summary: summary),
                       ExistingDataProbeResult.none)
        XCTAssertEqual(ExistingDataProbe.combine([.negative, .evidence], summary: summary), .found(summary))
    }

    func testOrderedFingerprintsPutsMarkerExtrasLast() {
        let ordered = ExistingDataProbe.orderedFingerprints(cloudKit: ["a": 1, "b": 5],
                                                            marker: ["b", "c"])
        XCTAssertEqual(ordered, ["b", "a", "c"])
    }

    // MARK: - Signal 3, the slow one

    /// The legacy sweep runs after the branch screen is up and refines what is
    /// shown. It can turn `.none` into `.found`.
    func testLegacyICloudDriveSweepUpgradesNoneToFound() async {
        let store = MockCloudKitMediaStore()
        let probe = makeProbe(marker: nil, store: store, legacyCount: 7)

        let probed = await probe.result()
        XCTAssertEqual(probed, ExistingDataProbeResult.none)

        guard case .found(let summary) = await probe.refineWithLegacyICloudDrive() else {
            return XCTFail("legacy iCloud Drive files are existing data")
        }
        XCTAssertEqual(summary.iCloudDriveFileCount, 7)
    }

    /// An unresolved sweep leaves the fast answer untouched — it must not
    /// manufacture a negative.
    func testUnresolvedLegacySweepLeavesResultAlone() async {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .indexUnavailable
        let probe = makeProbe(marker: nil, store: store, legacyCount: nil)

        let probed = await probe.refineWithLegacyICloudDrive()
        XCTAssertEqual(probed, .unknown)
    }

    /// `iCloudStorageModel.rootURL` `fatalError`s with no ubiquity container, which
    /// is exactly the case this probe runs in. The probe resolves the same path
    /// without it, and reports "no container" as nil rather than crashing.
    func testLegacyRootURLDoesNotTrapWithoutContainer() {
        let saved = iCloudStorageModel.testContainerRootOverride
        defer { iCloudStorageModel.testContainerRootOverride = saved }

        iCloudStorageModel.testContainerRootOverride = nil
        _ = LegacyICloudDriveSweep.legacyRootURL()   // must not trap

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe-root")
        iCloudStorageModel.testContainerRootOverride = scratch
        XCTAssertEqual(LegacyICloudDriveSweep.legacyRootURL(), scratch)
    }

    // MARK: - Session cache and stubs

    func testResultIsCachedForTheSession() async throws {
        let store = MockCloudKitMediaStore()
        try await seed(store, [upload(fingerprint: "ffff", id: "a")])
        let probe = makeProbe(marker: nil, store: store)

        _ = await probe.result()
        _ = await probe.result()
        _ = await probe.result()

        XCTAssertEqual(store.fingerprintCensusCount, 1, "branch screens must not re-probe")
    }

    /// The UITest stubs are what make the ENC-91..96 branch screens drivable in a
    /// simulator that has no iCloud account.
    func testStubbedSignalsBypassTheRealSources() async {
        let store = MockCloudKitMediaStore()
        store.accountAvailableValue = false
        ExistingDataProbeTestHooks.stubbedMarker = true
        ExistingDataProbeTestHooks.stubbedCloudKitCount = 12
        let probe = makeProbe(marker: nil, store: store)

        guard case .found(let summary) = await probe.result() else {
            return XCTFail("stubs must drive the probe without any real source")
        }
        XCTAssertTrue(summary.hasUsedMarker)
        XCTAssertEqual(summary.cloudKitMediaCount, 12)
        XCTAssertEqual(store.fingerprintCensusCount, 0)
    }

    func testStubbedTimeoutForcesUnknown() async {
        let store = MockCloudKitMediaStore()
        ExistingDataProbeTestHooks.forcesTimeout = true
        let probe = makeProbe(marker: MultiDeviceState(hasUsedEncamera: true), store: store)

        let probed = await probe.result()
        XCTAssertEqual(probed, .unknown)
    }

    func testStubbedCloudKitZeroIsATrustworthyNegative() async {
        let store = MockCloudKitMediaStore()
        ExistingDataProbeTestHooks.stubbedCloudKitCount = 0
        let probe = makeProbe(marker: nil, store: store)

        let probed = await probe.result()
        XCTAssertEqual(probed, ExistingDataProbeResult.none)
    }

    // MARK: - The provider seam used in production

    func testStoreComesFromTheCloudKitStoreProviderSeamByDefault() async {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .counted(mediaCount: 2, fingerprints: ["ab": 2])
        CloudKitStoreProvider.makeStore = { _ in store }

        let probe = ExistingDataProbe(budget: 2.0, stateProvider: { nil })

        guard case .found(let summary) = await probe.result() else {
            return XCTFail("expected the seam-bound store to be used")
        }
        XCTAssertEqual(summary.cloudKitMediaCount, 2)
    }

    // MARK: - ENC-96: Restore Purchases is a backstop-only signal

    /// The load-bearing safety property. A successful restore, with NO other
    /// evidence, must never manufacture a `.found` — a restore is proof of a prior
    /// purchase, not of recoverable data. A genuine new user who restores a
    /// subscription still resolves `.none` and proceeds to fresh setup un-gated.
    func testRestoreAloneDoesNotProduceFound() async {
        let store = MockCloudKitMediaStore()          // empty zone
        let probe = makeProbe(marker: nil, store: store)
        ExistingDataProbeTestHooks.stubbedCloudKitCount = 0   // trustworthy negative

        // Restore recorded BEFORE the probe runs, then the probe resolves.
        _ = await probe.recordRestoredPurchase()
        let resolved = await probe.result()
        XCTAssertEqual(resolved, ExistingDataProbeResult.none,
                       "A restore alone must never gate fresh setup")

        // ...and recording it AFTER a resolved negative must not upgrade it either.
        let afterwards = await probe.recordRestoredPurchase()
        XCTAssertEqual(afterwards, ExistingDataProbeResult.none,
                       "A restore must not upgrade a resolved `.none`")
    }

    /// A restore alone against an all-unresolved probe stays `.unknown` — it never
    /// creates a returning user out of "we could not tell".
    func testRestoreAloneLeavesUnknownUnknown() async {
        let store = MockCloudKitMediaStore()
        ExistingDataProbeTestHooks.forcesTimeout = true
        let probe = makeProbe(marker: nil, store: store)

        _ = await probe.result()                       // resolves `.unknown`
        let annotated = await probe.recordRestoredPurchase()
        XCTAssertEqual(annotated, .unknown,
                       "A restore must not turn `.unknown` into `.found`")
    }

    /// When data-bearing evidence already produced `.found`, the restore only
    /// annotates it — corroboration, never a change to the counts the destructive
    /// gate keys off.
    func testRestoreAnnotatesAnExistingFoundWithoutMovingCounts() async {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .counted(mediaCount: 4, fingerprints: ["ab": 4])
        let probe = makeProbe(marker: nil, store: store)

        guard case .found(let before) = await probe.result() else {
            return XCTFail("CloudKit media should have produced `.found`")
        }
        XCTAssertFalse(before.hasRestoredPurchase)

        guard case .found(let after) = await probe.recordRestoredPurchase() else {
            return XCTFail("annotating a `.found` must keep it `.found`")
        }
        XCTAssertTrue(after.hasRestoredPurchase, "the restore should be recorded")
        XCTAssertEqual(after.cloudKitMediaCount, before.cloudKitMediaCount,
                       "the restore must not move the CloudKit count the gate reads")
        XCTAssertEqual(after.iCloudDriveFileCount, 0,
                       "the restore must not move the legacy count the gate reads")
    }

    // MARK: - reset() vs an in-flight probe

    /// `reset()` exists "for tests and for a post-erase re-probe", and that second
    /// case is a race: the destructive path runs while a probe may still be
    /// outstanding. The probe's continuation used to write `cached = value`
    /// unconditionally, so the pre-erase probe resumed after the reset and put back
    /// a `.found` describing data that had just been deleted — routing the user
    /// into the returning-user branch again, immediately after erasing their way
    /// out of it.
    func testResetIsNotUndoneByAProbeAlreadyInFlight() async throws {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .counted(mediaCount: 4, fingerprints: ["ab": 4])
        store.fingerprintCensusDelayNanos = 400_000_000
        let probe = makeProbe(marker: nil, store: store, budget: 5.0)

        // The pre-erase probe, parked inside its census.
        let inFlight = Task { await probe.result() }
        try await Task.sleep(nanoseconds: 80_000_000)

        // The erase happens and the cache is dropped.
        await probe.reset()
        _ = await inFlight.value

        // The account is empty now. A probe that honoured the reset re-runs and
        // sees that; one that let the stale continuation write back reports the
        // deleted media as still present.
        store.fingerprintCensusOverride = .counted(mediaCount: 0, fingerprints: [:])
        store.fingerprintCensusDelayNanos = 0

        let after = await probe.result()
        XCTAssertEqual(after, ExistingDataProbeResult.none,
                       "a reset must survive the probe that was in flight when it happened")
    }
}
