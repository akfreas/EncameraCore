//
//  CloudKitSyncStatusReporterTests.swift
//  EncameraCoreTests
//
//  The reporter derives one user-facing activity from several independent
//  signals, so the interesting cases are the overlaps between them.
//

import XCTest
@testable import EncameraCore

@MainActor
final class CloudKitSyncStatusReporterTests: XCTestCase {

    /// A fresh instance, never `.shared`: this is observable state that would
    /// otherwise leak between tests.
    private func makeReporter() -> CloudKitSyncStatusReporter {
        CloudKitSyncStatusReporter()
    }

    func testStartsIdleWithNoSyncTime() {
        let reporter = makeReporter()
        XCTAssertEqual(reporter.activity, .idle)
        XCTAssertNil(reporter.lastSyncedAt)
    }

    func testReportsCheckingWhileReconciling() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        XCTAssertEqual(reporter.activity, .checking)
    }

    func testFinishedCheckGoesIdleAndStampsTheSyncTime() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        reporter.reportCheckFinished()
        XCTAssertEqual(reporter.activity, .idle)
        XCTAssertNotNil(reporter.lastSyncedAt)
    }

    func testUploadingOutranksChecking() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        reporter.reportUploadProgress(completed: 1, total: 4)
        XCTAssertEqual(reporter.activity, .uploading(completed: 1, total: 4))
    }

    func testUploadFractionIsBoundedAndOnlyDeterminateForUploads() {
        XCTAssertEqual(CloudKitSyncActivity.uploading(completed: 1, total: 4).fractionCompleted, 0.25)
        XCTAssertEqual(CloudKitSyncActivity.uploading(completed: 9, total: 4).fractionCompleted, 1)
        XCTAssertNil(CloudKitSyncActivity.uploading(completed: 0, total: 0).fractionCompleted)
        XCTAssertNil(CloudKitSyncActivity.checking.fractionCompleted)
        XCTAssertNil(CloudKitSyncActivity.idle.fractionCompleted)
    }

    func testFinishedUploadsClearProgressAndSurfaceStalledItems() {
        let reporter = makeReporter()
        reporter.reportUploadProgress(completed: 2, total: 5)
        reporter.reportUploadsFinished(stalled: 3)
        XCTAssertEqual(reporter.activity, .stalled(count: 3))
    }

    func testDrainingBacklogIsNotAlsoReportedAsStalled() {
        let reporter = makeReporter()
        reporter.reportUploadsFinished(stalled: 2)
        reporter.reportUploadProgress(completed: 0, total: 2)
        XCTAssertEqual(reporter.activity, .uploading(completed: 0, total: 2))
    }

    /// The whole point of staging: launch kicks an empty upload drain, which
    /// reports "nothing pending" and would otherwise wipe the staged state before
    /// a UI test could read it.
    func testStagedActivityOutlivesEveryProducerReport() {
        let reporter = makeReporter()
        reporter.stage(.stalled(count: 2))

        reporter.reportCheckStarted()
        reporter.reportUploadProgress(completed: 3, total: 3)
        reporter.reportUploadsFinished(stalled: 0)
        reporter.reportCheckFinished()

        XCTAssertEqual(reporter.activity, .stalled(count: 2))
    }

    func testStalledCountClearsOnceAPassAbandonsNothing() {
        let reporter = makeReporter()
        reporter.reportUploadsFinished(stalled: 2)
        reporter.reportUploadsFinished(stalled: 0)
        XCTAssertEqual(reporter.activity, .idle)
    }
}
