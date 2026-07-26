//
//  DebugLogBufferTests.swift
//  EncameraCoreTests
//
//  Created by Alexander Freas on 26.07.26.
//

import XCTest
@testable import EncameraCore

/// Every test builds its own buffer via the internal `init(capacity:)` so nothing
/// here touches `DebugLogBuffer.shared` or reads the real feature toggle, and
/// calls `setCapturing(true)` explicitly to skip lazy resolution.
final class DebugLogBufferTests: XCTestCase {

    private func makeBuffer(capacity: Int, capturing: Bool = true) -> DebugLogBuffer {
        let buffer = DebugLogBuffer(capacity: capacity)
        buffer.setCapturing(capturing)
        return buffer
    }

    // MARK: - Capture gate

    func testRecordIsNoOpWhenCaptureDisabled() {
        let buffer = makeBuffer(capacity: 10, capturing: false)
        let generationBefore = buffer.generation

        for index in 0..<20 {
            buffer.record(category: "Test", message: "line \(index)")
        }

        XCTAssertEqual(buffer.stats.retained, 0)
        XCTAssertEqual(buffer.stats.totalRecorded, 0)
        XCTAssertEqual(buffer.generation, generationBefore, "A dropped line must not bump the generation")
        XCTAssertTrue(buffer.snapshot().isEmpty)
    }

    func testDisablingCaptureClearsBuffer() {
        let buffer = makeBuffer(capacity: 10)
        buffer.record(category: "Test", message: "kept until disabled")
        XCTAssertEqual(buffer.stats.retained, 1)

        buffer.setCapturing(false)

        XCTAssertEqual(buffer.stats.retained, 0)
        XCTAssertFalse(buffer.stats.isCapturing)
        XCTAssertTrue(buffer.snapshot().isEmpty)
    }

    func testGenerationChangesOnCaptureStateChange() {
        let buffer = makeBuffer(capacity: 10)
        let before = buffer.generation
        buffer.setCapturing(false)
        XCTAssertNotEqual(buffer.generation, before, "An open viewer needs to notice the state change")
    }

    // MARK: - Eviction

    func testEvictsOldestBeyondCapacity() {
        let buffer = makeBuffer(capacity: 10)

        for index in 0..<15 {
            buffer.record(category: "Test", message: "line \(index)")
        }

        let stats = buffer.stats
        XCTAssertEqual(stats.retained, 10)
        XCTAssertEqual(stats.totalRecorded, 15)
        XCTAssertEqual(stats.evicted, 5)

        let chronological = buffer.snapshot(newestFirst: false)
        XCTAssertEqual(chronological.count, 10)
        XCTAssertEqual(chronological.first?.message, "line 5", "Oldest five should have been dropped")
        XCTAssertEqual(chronological.last?.message, "line 14")
        XCTAssertEqual(chronological.map(\.id), Array(5..<15).map(UInt64.init))
    }

    func testSnapshotOrdering() {
        let buffer = makeBuffer(capacity: 10)
        for index in 0..<5 {
            buffer.record(category: "Test", message: "line \(index)")
        }

        let newestFirst = buffer.snapshot(newestFirst: true)
        let oldestFirst = buffer.snapshot(newestFirst: false)

        XCTAssertEqual(newestFirst.map(\.id), Array(oldestFirst.map(\.id).reversed()))
        XCTAssertEqual(newestFirst.first?.message, "line 4")
        XCTAssertEqual(oldestFirst.first?.message, "line 0")
    }

    func testRingBufferWrapsRepeatedlyWithoutCorruption() {
        let capacity = 8
        let buffer = makeBuffer(capacity: capacity)

        // Several full wraps to shake out head/index arithmetic.
        for index in 0..<(capacity * 5 + 3) {
            buffer.record(category: "Test", message: "line \(index)")
        }

        let chronological = buffer.snapshot(newestFirst: false)
        XCTAssertEqual(chronological.count, capacity)
        // ids must remain strictly ascending with no gaps at the wrap point.
        let ids = chronological.map(\.id)
        XCTAssertEqual(ids, Array(ids.first!...ids.last!))
        XCTAssertEqual(chronological.last?.message, "line \(capacity * 5 + 2)")
    }

    // MARK: - Byte budget

    func testByteBudgetEvictsBelowCapacity() {
        let capacity = 4_000
        let buffer = makeBuffer(capacity: capacity)

        // Each message is at the truncation limit, so the byte budget binds well
        // before the entry-count cap does.
        let large = String(repeating: "x", count: DebugLogBuffer.maxMessageCharacters)
        for _ in 0..<capacity {
            buffer.record(category: "Test", message: large)
        }

        let stats = buffer.stats
        XCTAssertLessThan(stats.retained, capacity, "Byte budget should bind before the entry cap")
        XCTAssertGreaterThan(stats.evicted, 0)
        XCTAssertEqual(stats.totalRecorded, UInt64(capacity))

        let retainedBytes = buffer.snapshot().reduce(0) { $0 + $1.approximateByteCount }
        XCTAssertLessThanOrEqual(retainedBytes, DebugLogBuffer.byteBudget)
    }

    func testSingleOversizedEntryIsStillRetained() {
        let buffer = makeBuffer(capacity: 10)
        // Truncation caps any one entry well under the budget, so one huge line
        // must never evict itself down to nothing.
        buffer.record(category: "Test", message: String(repeating: "y", count: 500_000))
        XCTAssertEqual(buffer.stats.retained, 1)
    }

    // MARK: - Truncation

    func testLongMessageIsTruncated() {
        let buffer = makeBuffer(capacity: 10)
        let overage = 500
        buffer.record(
            category: "Test",
            message: String(repeating: "z", count: DebugLogBuffer.maxMessageCharacters + overage)
        )

        let message = buffer.snapshot().first?.message
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.hasSuffix("… [truncated \(overage) chars]"))
        XCTAssertTrue(message!.hasPrefix(String(repeating: "z", count: 100)))
    }

    func testShortMessageIsNotTruncated() {
        let buffer = makeBuffer(capacity: 10)
        buffer.record(category: "Test", message: "short")
        XCTAssertEqual(buffer.snapshot().first?.message, "short")
    }

    // MARK: - Clear

    func testClearPreservesLifetimeCounters() {
        let buffer = makeBuffer(capacity: 5)
        for index in 0..<8 {
            buffer.record(category: "Test", message: "line \(index)")
        }

        buffer.clear()

        let stats = buffer.stats
        XCTAssertEqual(stats.retained, 0)
        XCTAssertEqual(stats.totalRecorded, 8, "Lifetime recorded count should survive a clear")
        XCTAssertEqual(stats.evicted, 3)
        XCTAssertTrue(stats.isCapturing, "Clearing must not turn capture off")

        // Still usable afterwards.
        buffer.record(category: "Test", message: "after clear")
        XCTAssertEqual(buffer.stats.retained, 1)
        XCTAssertEqual(buffer.snapshot().first?.message, "after clear")
    }

    // MARK: - Concurrency

    /// Run this under the Thread Sanitizer: `printDebug` is the app's most-called
    /// function, and it is invoked from actors and arbitrary threads.
    func testConcurrentWritesAreSafe() {
        let capacity = 1_000
        let buffer = makeBuffer(capacity: capacity)
        let threads = 8
        let perThread = 5_000

        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for index in 0..<perThread {
                buffer.record(category: "Thread\(thread)", message: "line \(index)")
            }
        }

        let stats = buffer.stats
        XCTAssertEqual(stats.retained, capacity)
        XCTAssertEqual(stats.totalRecorded, UInt64(threads * perThread))
        XCTAssertEqual(stats.evicted, UInt64(threads * perThread - capacity))

        let ids = buffer.snapshot().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Every entry must get a unique id")
    }

    func testConcurrentReadsAndWritesAreSafe() {
        let buffer = makeBuffer(capacity: 500)
        let expectation = expectation(description: "readers and writers finish")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for index in 0..<20_000 {
                buffer.record(category: "Writer", message: "line \(index)")
            }
            expectation.fulfill()
        }

        DispatchQueue.global().async {
            for _ in 0..<2_000 {
                _ = buffer.snapshot()
                _ = buffer.stats
                _ = buffer.generation
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 60)
        XCTAssertEqual(buffer.stats.totalRecorded, 20_000)
    }
}
