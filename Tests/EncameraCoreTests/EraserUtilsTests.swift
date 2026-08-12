//
//  EraserUtilsTests.swift
//  EncameraCoreTests
//
//  Covers the erase contracts: the `.allData` wipe must invoke CloudKit deletion,
//  run EVERY local step even when the cloud delete fails (asserted through the
//  recording seam, not inferred from "did not throw"), gate the "iCloud data may
//  remain" warning on plausible cloud usage, and persist the pending-wipe marker;
//  `.appData` must sweep derived caches without touching CloudKit or media files.
//  Both seams are mocks, so no real defaults, keychain, or filesystem are wiped
//  in the test process.
//

import XCTest
@testable import EncameraCore

final class EraserUtilsTests: XCTestCase {

    private final class MockCloudDataEraser: CloudDataErasing {
        var error: Error?
        var mayHaveData = true
        private(set) var callCount = 0
        func deleteAllCloudData() async throws {
            callCount += 1
            if let error { throw error }
        }
        func mayHaveCloudKitData() async -> Bool { mayHaveData }
    }

    private final class RecordingLocalEraser: LocalDataErasing {
        private(set) var steps: [String] = []
        func eraseMigrationState() async { steps.append("migrationState") }
        func eraseActiveBackendMedia() async { steps.append("activeBackendMedia") }
        func eraseAllLocalMediaFiles() { steps.append("allLocalMediaFiles") }
        func eraseMediaIndexes() { steps.append("mediaIndexes") }
        func eraseBlobCache() async { steps.append("blobCache") }
        func eraseThumbnails() { steps.append("thumbnails") }
        func eraseTempDirectories() { steps.append("tempDirectories") }
        func eraseSharedContainerImports() async { steps.append("sharedContainerImports") }
        func eraseKeychain() { steps.append("keychain") }
        func eraseUserDefaults() { steps.append("userDefaults") }
        func recordPendingCloudWipe() { steps.append("pendingCloudWipe") }
    }

    private static let allDataSteps = [
        "migrationState", "activeBackendMedia", "allLocalMediaFiles", "mediaIndexes",
        "blobCache", "thumbnails", "tempDirectories", "sharedContainerImports",
        "keychain", "userDefaults"
    ]

    private func makeUtils(scope: ErasureScope,
                           cloud: CloudDataErasing,
                           local: LocalDataErasing) -> EraserUtils {
        EraserUtils(keyManager: DemoKeyManager(),
                    fileAccess: InteractableMediaFileAccess(),
                    erasureScope: scope,
                    cloudKitEraser: cloud,
                    localEraser: local)
    }

    func testEraseAllDataDeletesCloudKitDataAndRunsEveryLocalStep() async throws {
        let cloud = MockCloudDataEraser()
        let local = RecordingLocalEraser()

        let result = try await makeUtils(scope: .allData, cloud: cloud, local: local).erase()

        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertFalse(result.cloudKitDeletionFailed)
        XCTAssertEqual(local.steps, Self.allDataSteps,
                       "every local step runs, in order, with no pending-wipe marker on success")
    }

    func testEraseAllDataCloudFailureStillRunsEveryLocalStepAndPersistsMarker() async throws {
        let cloud = MockCloudDataEraser()
        cloud.error = NSError(domain: "test", code: 1)
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

        let result = try await makeUtils(scope: .allData, cloud: cloud, local: local).erase()

        XCTAssertFalse(result.cloudKitDeletionFailed,
                       "no plausible cloud data means no false-positive warning")
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
}
