//
//  EraserUtilsTests.swift
//  EncameraCoreTests
//
//  Covers the erase contracts: the `.allData` wipe must invoke CloudKit deletion,
//  run EVERY local step even when the cloud delete fails (asserted through the
//  recording seam, not inferred from "did not throw"), gate the "iCloud data may
//  remain" warning on plausible cloud usage, persist the pending-wipe marker,
//  report every step running-then-terminal, and let a step's verification —
//  never its erase call — decide the outcome. `.appData` must sweep derived
//  caches without touching CloudKit or media files. Every seam is a mock, so no
//  real defaults, keychain, or filesystem are wiped in the test process.
//

import XCTest
@testable import EncameraCore

final class EraserUtilsTests: XCTestCase {

    private final class MockCloudDataEraser: CloudDataErasing {
        var error: Error?
        var subscriptionError: Error?
        var mayHaveData = true
        /// What a re-read reports after the delete; a server that committed the
        /// delete despite a client-side error reports nothing.
        var zonesAfterDelete: [String] = []
        var subscriptionsAfterDelete: [String] = []
        var readError: Error?
        private(set) var callCount = 0
        private(set) var subscriptionDeleteCount = 0

        func deleteAllCloudData() async throws {
            callCount += 1
            if let error { throw error }
        }
        func deleteAllSubscriptions() async throws {
            subscriptionDeleteCount += 1
            if let subscriptionError { throw subscriptionError }
        }
        func remainingZoneNames() async throws -> [String] {
            if let readError { throw readError }
            return zonesAfterDelete
        }
        func remainingSubscriptionIDs() async throws -> [String] {
            if let readError { throw readError }
            return subscriptionsAfterDelete
        }
        func mayHaveCloudKitData() async -> Bool { mayHaveData }
    }

    private final class RecordingLocalEraser: LocalDataErasing {
        private(set) var steps: [String] = []
        func shutdownCloudKitSync() async { steps.append("shutdownCloudKitSync") }
        func eraseMigrationState() async { steps.append("migrationState") }
        func eraseActiveBackendMedia() async { steps.append("activeBackendMedia") }
        func eraseAllLocalMediaFiles() { steps.append("allLocalMediaFiles") }
        func eraseICloudDriveMedia() { steps.append("iCloudDriveMedia") }
        func eraseMediaIndexes() { steps.append("mediaIndexes") }
        func eraseBlobCache() async { steps.append("blobCache") }
        func eraseThumbnails() { steps.append("thumbnails") }
        func eraseTempDirectories() { steps.append("tempDirectories") }
        func eraseSharedContainerImports() async { steps.append("sharedContainerImports") }
        func eraseResidualContainerFiles() { steps.append("residualContainerFiles") }
        func eraseKeychain() { steps.append("keychain") }
        func eraseUserDefaults() { steps.append("userDefaults") }
        func recordPendingCloudWipe() { steps.append("pendingCloudWipe") }
    }

    /// Answers every verification with a scripted verdict, so a test can make one
    /// step "dirty" and watch what the runner does about it.
    private final class ScriptedVerifier: LocalDataVerifying {
        var failing: [String: ErasureVerdict] = [:]
        private(set) var verified: [String] = []

        private func verdict(_ id: String) -> ErasureVerdict {
            verified.append(id)
            return failing[id] ?? .pass("\(id) clear")
        }
        func verifyCloudKitSyncShutdown() async -> ErasureVerdict { verdict("sync.shutdown") }
        func verifyMigrationState() async -> ErasureVerdict { verdict("migration.state") }
        func verifyActiveBackendMedia() async -> ErasureVerdict { verdict("media.activeBackend") }
        func verifyLocalMediaFiles() -> ErasureVerdict { verdict("media.localAlbums") }
        func verifyICloudDriveMedia() -> ErasureVerdict { verdict("media.iCloudDrive") }
        func verifyMediaIndexes() -> ErasureVerdict { verdict("media.indexes") }
        func verifyBlobCache() -> ErasureVerdict { verdict("media.blobCache") }
        func verifyThumbnails() -> ErasureVerdict { verdict("media.thumbnails") }
        func verifyTempDirectories() -> ErasureVerdict { verdict("media.temp") }
        func verifySharedContainerImports() -> ErasureVerdict { verdict("media.sharedImports") }
        func verifyResidualContainerFiles() -> ErasureVerdict { verdict("sweep.residual") }
        func verifyKeychain() -> ErasureVerdict { verdict("keys.keychain") }
        func verifyUserDefaults() -> ErasureVerdict { verdict("settings.defaults") }
        func verifyDeviceClean() async -> ErasureVerdict { verdict("final.verify") }
    }

    private static let allDataSteps = [
        "migrationState", "shutdownCloudKitSync", "activeBackendMedia", "allLocalMediaFiles", "iCloudDriveMedia", "mediaIndexes",
        "blobCache", "thumbnails", "tempDirectories", "sharedContainerImports",
        "residualContainerFiles", "keychain", "userDefaults"
    ]

    private func makeUtils(scope: ErasureScope,
                           cloud: CloudDataErasing,
                           local: LocalDataErasing,
                           verifier: LocalDataVerifying = ScriptedVerifier(),
                           appLayerSteps: [ErasureStep] = []) -> EraserUtils {
        EraserUtils(keyManager: DemoKeyManager(),
                    fileAccess: InteractableMediaFileAccess(),
                    erasureScope: scope,
                    cloudKitEraser: cloud,
                    localEraser: local,
                    localVerifier: verifier,
                    appLayerSteps: appLayerSteps)
    }

    /// Collects progress reports on the calling task, in order.
    private final class ProgressLog: @unchecked Sendable {
        private(set) var reports: [ErasureStepReport] = []
        func record(_ report: ErasureStepReport) { reports.append(report) }
    }

    // MARK: - Sequence

    func testEraseAllDataDeletesCloudKitDataAndRunsEveryLocalStep() async throws {
        let cloud = MockCloudDataEraser()
        let local = RecordingLocalEraser()

        let result = try await makeUtils(scope: .allData, cloud: cloud, local: local).erase()

        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertEqual(cloud.subscriptionDeleteCount, 1, "the zone subscription is a record of its own")
        XCTAssertFalse(result.cloudKitDeletionFailed)
        XCTAssertEqual(local.steps, Self.allDataSteps,
                       "every local step runs, in order, with no pending-wipe marker on success")
    }

    func testEraseAllDataCloudFailureStillRunsEveryLocalStepAndPersistsMarker() async throws {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        cloud.readError = NSError(domain: "test", code: 2)
        let local = RecordingLocalEraser()

        let result = try await makeUtils(scope: .allData, cloud: cloud, local: local).erase()

        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertTrue(result.cloudKitDeletionFailed)
        XCTAssertEqual(local.steps, Self.allDataSteps + ["pendingCloudWipe"],
                       "a cloud failure must not skip any local step, and the owed cloud wipe is persisted AFTER the defaults wipe")
    }

    func testEraseAllDataCloudFailureWithoutCloudUsageSuppressesWarningButKeepsRetryMarker() async throws {
        // A signed-out user whose `hasEverProvisionedZone` flag was destroyed (an
        // `.appData` reset wipes defaults; a reinstall loses them entirely) can
        // still have a vault full of photos in the private database. The
        // heuristic may suppress the unactionable ALERT — but the durable retry
        // marker must be persisted on every non-benign failure: the launch-time
        // retry is free and self-clearing (a missing zone is benign success).
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        cloud.mayHaveData = false
        let local = RecordingLocalEraser()
        let log = ProgressLog()

        let report = await makeUtils(scope: .allData, cloud: cloud, local: local)
            .eraseAllData(progress: { log.record($0) })

        XCTAssertFalse(report.cloudKitDeletionFailed,
                       "no plausible cloud data means no false-positive warning")
        XCTAssertEqual(report.report(for: "cloud.zones")?.outcome, .skipped,
                       "a device with no account has nothing in iCloud to fail on")
        XCTAssertEqual(local.steps, Self.allDataSteps + ["pendingCloudWipe"],
                       "the owed cloud wipe is persisted even when the warning is suppressed")
    }

    func testEraseAppDataSweepsDerivedCachesWithoutTouchingCloudKitOrMediaFiles() async throws {
        let cloud = MockCloudDataEraser()
        let local = RecordingLocalEraser()

        let result = try await makeUtils(scope: .appData, cloud: cloud, local: local).erase()

        XCTAssertEqual(cloud.callCount, 0, "appData never touches CloudKit — keys may survive on other devices")
        XCTAssertFalse(result.cloudKitDeletionFailed)
        XCTAssertEqual(local.steps,
                       ["migrationState", "mediaIndexes", "blobCache", "thumbnails",
                        "tempDirectories", "sharedContainerImports", "keychain", "userDefaults"],
                       "appData sweeps every DERIVED cache but keeps encrypted originals")
        XCTAssertFalse(local.steps.contains("activeBackendMedia"))
        XCTAssertFalse(local.steps.contains("allLocalMediaFiles"))
    }

    /// The Share Extension hands over DECRYPTED media, so the App Group import
    /// directory is cleartext on disk. It is swept by both scopes — `.appData`
    /// preserves encrypted originals, and this is not one of them.
    func testBothScopesClearTheCleartextSharedContainerImports() async throws {
        for scope in [ErasureScope.allData, .appData] {
            let local = RecordingLocalEraser()
            _ = try await makeUtils(scope: scope, cloud: MockCloudDataEraser(), local: local).erase()
            XCTAssertTrue(local.steps.contains("sharedContainerImports"),
                          "\(scope) left the Share Extension's cleartext imports on disk")
        }
    }

    // MARK: - Progress reporting

    func testEveryCatalogStepIsReportedRunningThenTerminalInOrder() async {
        let utils = makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: RecordingLocalEraser())
        let log = ProgressLog()

        let report = await utils.eraseAllData(progress: { log.record($0) })

        let expectedIDs = utils.stepDescriptors.map(\.id)
        XCTAssertEqual(expectedIDs, ErasureStepDescriptor.allDataCatalog.map(\.id))
        XCTAssertEqual(log.reports.filter { $0.outcome == .running }.map(\.id), expectedIDs,
                       "each step announces itself before it runs")
        XCTAssertEqual(log.reports.filter { $0.outcome != .running }.map(\.id), expectedIDs,
                       "each step lands exactly one terminal report, in run order")
        XCTAssertEqual(report.steps.map(\.id), expectedIDs)
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.markerText, "complete:ok=\(expectedIDs.count)/\(expectedIDs.count):fail=")
    }

    func testAFailedVerificationMarksOnlyThatStepAndTheRunContinues() async {
        let verifier = ScriptedVerifier()
        verifier.failing["keys.keychain"] = .residue("keychain items", names: ["GenericPassword|encamera"], hint: .keychain)
        let local = RecordingLocalEraser()
        let utils = makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: local, verifier: verifier)

        let report = await utils.eraseAllData(progress: { _ in })

        XCTAssertEqual(report.failures.map(\.id), ["keys.keychain"])
        XCTAssertEqual(report.report(for: "keys.keychain")?.hint, .keychain)
        XCTAssertEqual(report.report(for: "settings.defaults")?.outcome, .pass, "later steps still run")
        XCTAssertEqual(report.report(for: "final.verify")?.outcome, .pass)
        XCTAssertEqual(local.steps, Self.allDataSteps, "a failed verification never skips an erase")
        let total = utils.stepDescriptors.count
        XCTAssertEqual(report.markerText, "complete:ok=\(total - 1)/\(total):fail=keys.keychain")
    }

    /// The outcome belongs to the verification, not to the erase call: an erase
    /// that throws but leaves nothing behind is a pass, and one that returns
    /// quietly over surviving data is a failure.
    func testVerificationDecidesTheOutcomeNotTheEraseCall() async {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        cloud.zonesAfterDelete = []
        let report = await makeUtils(scope: .allData, cloud: cloud, local: RecordingLocalEraser())
            .eraseAllData(progress: { _ in })

        let zones = report.report(for: "cloud.zones")
        XCTAssertEqual(zones?.outcome, .pass, "the server committed the delete despite the client error")
        XCTAssertTrue(zones?.detail.contains("erase error") == true, "the error is kept as evidence")

        let stubborn = MockCloudDataEraser()
        stubborn.zonesAfterDelete = ["EncameraZone"]
        let dirty = await makeUtils(scope: .allData, cloud: stubborn, local: RecordingLocalEraser())
            .eraseAllData(progress: { _ in })
        XCTAssertEqual(dirty.report(for: "cloud.zones")?.outcome, .fail, "a zone that is still there is a failure however the delete returned")
        XCTAssertEqual(dirty.report(for: "cloud.zones")?.hint, .cloudUnreachable)
    }

    func testUnreachableCloudReadIsAFailureWithTheRetryHint() async {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
        cloud.readError = NSError(domain: "test", code: 2)
        let report = await makeUtils(scope: .allData, cloud: cloud, local: RecordingLocalEraser())
            .eraseAllData(progress: { _ in })

        XCTAssertEqual(report.report(for: "cloud.zones")?.outcome, .fail)
        XCTAssertEqual(report.report(for: "cloud.zones")?.hint, .cloudUnreachable)
        XCTAssertTrue(report.cloudKitDeletionFailed)
    }

    func testSurvivingSubscriptionFailsTheSubscriptionStep() async {
        let cloud = MockCloudDataEraser()
        cloud.subscriptionsAfterDelete = ["EncameraZoneSubscription"]
        let report = await makeUtils(scope: .allData, cloud: cloud, local: RecordingLocalEraser())
            .eraseAllData(progress: { _ in })

        XCTAssertEqual(report.report(for: "cloud.subscriptions")?.outcome, .fail)
        XCTAssertEqual(report.report(for: "cloud.zones")?.outcome, .pass)
    }

    // MARK: - App-layer steps

    func testAppLayerStepsRunAfterMediaAndBeforeTheResidualSweepKeychainAndDefaults() async {
        let local = RecordingLocalEraser()
        let order = ProgressLog()
        let step = ErasureStep(
            descriptor: .init(id: "app.purchases", title: "Sign out of purchases", section: .app),
            erase: { order.record(.running("app.purchases:erase:\(local.steps.count)")) },
            verify: { .pass("signed out") }
        )
        let utils = makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: local, appLayerSteps: [step])

        let report = await utils.eraseAllData(progress: { _ in })

        // The erase closure recorded how many local steps had already run when it
        // fired: everything through the shared-imports sweep, and nothing after.
        let mediaSteps = Self.allDataSteps.firstIndex(of: "residualContainerFiles")!
        XCTAssertEqual(order.reports.first?.id, "app.purchases:erase:\(mediaSteps)",
                       "app-layer steps run before the residual sweep, keychain and defaults wipes so what they write is wiped too")
        XCTAssertEqual(report.report(for: "app.purchases")?.outcome, .pass)

        let ids = utils.stepDescriptors.map(\.id)
        XCTAssertLessThan(ids.firstIndex(of: "media.sharedImports")!, ids.firstIndex(of: "app.purchases")!)
        XCTAssertLessThan(ids.firstIndex(of: "app.purchases")!, ids.firstIndex(of: "sweep.residual")!)
        XCTAssertEqual(utils.stepDescriptors.first { $0.id == "app.purchases" }?.section, .app)
    }

    func testAThrowingAppLayerStepIsJudgedByItsVerification() async {
        let throwing = ErasureStep(
            descriptor: .init(id: "app.analytics", title: "Delete analytics", section: .app),
            erase: { throw NSError(domain: "sdk", code: 9) },
            verify: { .fail("event store still present", hint: .retry) }
        )
        let report = await makeUtils(scope: .allData, cloud: MockCloudDataEraser(), local: RecordingLocalEraser(),
                                     appLayerSteps: [throwing])
            .eraseAllData(progress: { _ in })

        XCTAssertEqual(report.report(for: "app.analytics")?.outcome, .fail)
        XCTAssertEqual(report.report(for: "app.analytics")?.hint, .retry)
        XCTAssertEqual(report.report(for: "final.verify")?.outcome, .pass, "the run carried on")
    }
}
