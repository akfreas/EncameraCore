//
//  DebugLogFormatterTests.swift
//  EncameraCoreTests
//
//  Created by Alexander Freas on 26.07.26.
//

import XCTest
@testable import EncameraCore

final class DebugLogFormatterTests: XCTestCase {

    private func makeEntry(
        id: UInt64,
        message: String,
        category: String = "DiskFileAccess",
        isMainThread: Bool = true
    ) -> DebugLogEntry {
        DebugLogEntry(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_774_534_500),
            category: category,
            message: message,
            isMainThread: isMainThread
        )
    }

    func testLineIncludesTimestampThreadCategoryAndMessage() {
        let formatter = DebugLogFormatter.makeLineFormatter()
        let line = DebugLogFormatter.line(for: makeEntry(id: 0, message: "opened album"), formatter: formatter)

        XCTAssertTrue(line.contains("[main]"))
        XCTAssertTrue(line.contains("DiskFileAccess:"))
        XCTAssertTrue(line.hasSuffix("opened album"))
        // Timestamp prefix, POSIX-formatted regardless of device region.
        XCTAssertTrue(line.hasPrefix(formatter.string(from: Date(timeIntervalSince1970: 1_774_534_500))))
    }

    func testBackgroundThreadIsLabelled() {
        let formatter = DebugLogFormatter.makeLineFormatter()
        let line = DebugLogFormatter.line(
            for: makeEntry(id: 0, message: "decrypting", isMainThread: false),
            formatter: formatter
        )
        XCTAssertTrue(line.contains("[bg]"))
    }

    func testPlainTextPreservesGivenOrderAndEmitsOneLinePerEntry() {
        let entries = (0..<3).map { makeEntry(id: UInt64($0), message: "line \($0)") }
        let text = DebugLogFormatter.plainText(entries: entries)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("line 0"))
        XCTAssertTrue(lines[2].hasSuffix("line 2"), "plainText must not reorder; the caller controls order")
    }

    func testPlainTextIncludesHeader() {
        let header = "Encamera debug log export\nFilter:   \"import\"\n---"
        let text = DebugLogFormatter.plainText(entries: [makeEntry(id: 0, message: "hello")], header: header)

        XCTAssertTrue(text.hasPrefix(header))
        XCTAssertTrue(text.contains("hello"))
    }

    func testPlainTextAddsNewlineAfterHeaderWithoutOne() {
        let text = DebugLogFormatter.plainText(entries: [makeEntry(id: 0, message: "hello")], header: "HEADER")
        XCTAssertTrue(text.hasPrefix("HEADER\n"), "Header must not run into the first log line")
    }

    func testMultiLineMessageIsPreservedVerbatim() {
        // Some callers dump JSON/metadata; rewriting newlines would corrupt it.
        let text = DebugLogFormatter.plainText(entries: [makeEntry(id: 0, message: "{\n  \"a\": 1\n}")])
        XCTAssertTrue(text.contains("{\n  \"a\": 1\n}"))
    }

    func testEmptyEntriesProducesHeaderOnly() {
        XCTAssertEqual(DebugLogFormatter.plainText(entries: []), "")
        XCTAssertEqual(DebugLogFormatter.plainText(entries: [], header: "H"), "H\n")
    }
}
