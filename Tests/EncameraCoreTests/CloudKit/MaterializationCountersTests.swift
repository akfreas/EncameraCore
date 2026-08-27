//
//  MaterializationCountersTests.swift
//  EncameraCoreTests
//
//  The counters the iCloud Drive device suite reads, and the one property that
//  keeps them honest across the batch loop: reset() must be total.
//

import XCTest
@testable import EncameraCore

/// `ICloudDriveMigrationObserver` is a singleton reused across the three batch
/// sizes in `testEveryBatchSizeCompletesAndStillBoundsPeakDisk`, so a counter
/// that survives `reset()` does not crash — it makes the next size's assertion
/// pass against the previous size's number. These tests assert over whatever
/// fields the marker publishes rather than naming them, so a counter added later
/// is covered without editing this file.
@MainActor
final class MaterializationCountersTests: XCTestCase {

    private var observer: ICloudDriveMigrationObserver { .shared }

    override func setUp() async throws {
        try await super.setUp()
        observer.reset()
        observer.isEnabled = true
    }

    override func tearDown() async throws {
        observer.isEnabled = false
        observer.reset()
        try await super.tearDown()
    }

    /// Every `name=value` field of the published label, as integers.
    private func publishedFields() -> [String: Int] {
        var fields: [String: Int] = [:]
        for field in observer.counters.markerLabel.split(separator: ":") {
            guard let separator = field.firstIndex(of: "="),
                  let value = Int(field[field.index(after: separator)...]) else {
                XCTFail("marker field '\(field)' is not name=<int>")
                continue
            }
            fields[String(field[field.startIndex..<separator])] = value
        }
        return fields
    }

    func testAFreshObserverPublishesEveryFieldAtZero() {
        let fields = publishedFields()
        XCTAssertFalse(fields.isEmpty, "the marker must publish at least one counter")
        for (name, value) in fields {
            XCTAssertEqual(value, 0, "\(name) is not zero on a fresh observer")
        }
    }

    func testTheLabelReportsWhatTheEngineRecorded() {
        observer.recordBatch(size: 10, alreadyMaterialized: 2)
        observer.recordBatch(size: 4, alreadyMaterialized: 7)
        observer.recordBatchResolved(byDeadline: false)
        observer.recordBatchResolved(byDeadline: true)
        observer.recordEviction(evicted: 5, materializedAtStop: 6)

        let fields = publishedFields()
        XCTAssertEqual(fields["batches"], 2)
        XCTAssertEqual(fields["maxBatch"], 10, "maxBatch must be the largest batch, not the last")
        XCTAssertEqual(fields["peakOnDisk"], 7, "peakOnDisk must be the highest seen, not the last")
        XCTAssertEqual(fields["observedBatches"], 1)
        XCTAssertEqual(fields["deadlineBatches"], 1)
        XCTAssertEqual(fields["evicted"], 5)
        XCTAssertEqual(fields["onDiskAtStop"], 6)
    }

    /// The load-bearing one. `reset()` assigns a whole default-initialized value,
    /// so it cannot skip a member; this pins the other half of that — that the
    /// default value really is all-zero, whatever the field list grows to.
    func testResetZeroesEveryFieldTheMarkerPublishes() {
        observer.recordBatch(size: 10, alreadyMaterialized: 3)
        observer.recordBatchResolved(byDeadline: false)
        observer.recordBatchResolved(byDeadline: true)
        observer.recordEviction(evicted: 5, materializedAtStop: 6)
        XCTAssertTrue(publishedFields().values.contains { $0 > 0 },
                      "the recordings above must move at least one counter")

        observer.reset()

        for (name, value) in publishedFields() {
            XCTAssertEqual(value, 0, "\(name) survived reset()")
        }
        XCTAssertEqual(observer.counters, MaterializationCounters())
    }

    // MARK: - confirmEviction

    /// Two confirmations in flight at once must both land.
    ///
    /// `confirmEviction` hands its work to a detached `@MainActor` task, so a
    /// pause-resume-pause inside its 10s window starts a second one while the
    /// first is still running. Reading a starting value OUTSIDE the task makes
    /// both compute from the same base, and whichever writes last erases the
    /// other's contribution — silently, as a number a device test then asserts
    /// on. Both calls below are made before either task body runs.
    func testOverlappingConfirmationsBothCount() async {
        let evicted = (0..<4).map {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("counters-\($0).encimage")
                .standardizedFileURL
        }
        ICloudPlaceholderName.testEvictedURLs = Set(evicted)
        defer { ICloudPlaceholderName.testEvictedURLs = nil }

        observer.confirmEviction(of: Array(evicted[0..<2]))
        observer.confirmEviction(of: Array(evicted[2..<4]))

        for _ in 0..<200 {
            if observer.counters.evictedVerified >= 4 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(observer.counters.evictedVerified, 4,
                       "each call must contribute its own files, not overwrite the other's")
    }

    /// Nothing is counted unless the app switched the observer on, so a shipped
    /// build never pays for it.
    func testRecordingIsInertWhileDisabled() {
        observer.isEnabled = false
        observer.recordBatch(size: 10, alreadyMaterialized: 3)
        observer.recordBatchResolved(byDeadline: true)
        observer.recordEviction(evicted: 5, materializedAtStop: 6)
        XCTAssertEqual(observer.counters, MaterializationCounters())
    }
}
