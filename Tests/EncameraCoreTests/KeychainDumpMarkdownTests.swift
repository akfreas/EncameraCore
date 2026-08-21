//
//  KeychainDumpMarkdownTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class KeychainDumpMarkdownTests: XCTestCase {

    private func makeEntry(
        itemClass: String = "Generic Password",
        displayName: String = "encamera",
        isSynchronizable: Bool = false,
        attributes: [KeychainDumpAttribute]
    ) -> KeychainDumpEntry {
        KeychainDumpEntry(
            itemClass: itemClass,
            displayName: displayName,
            isSynchronizable: isSynchronizable,
            attributes: attributes
        )
    }

    func testSingleEntryRendersHeadingAndAttributeTable() {
        let entry = makeEntry(attributes: [
            KeychainDumpAttribute(label: "Account", rawKey: "acct", value: "encamera"),
            KeychainDumpAttribute(label: "iCloud Sync", rawKey: "sync", value: "No")
        ])

        let markdown = KeychainDumpMarkdown.markdown(for: entry, redacted: false)

        XCTAssertTrue(markdown.hasPrefix("## Generic Password · encamera\n"))
        XCTAssertTrue(markdown.contains("| Attribute | Raw Key | Value |"))
        XCTAssertTrue(markdown.contains("| Account | acct | encamera |"))
        XCTAssertTrue(markdown.contains("| iCloud Sync | sync | No |"))
    }

    func testSynchronizableEntryHeadingIsFlagged() {
        let entry = makeEntry(isSynchronizable: true, attributes: [])

        let markdown = KeychainDumpMarkdown.markdown(for: entry, redacted: false)

        XCTAssertTrue(markdown.hasPrefix("## Generic Password · encamera (iCloud synced)\n"))
    }

    func testRedactionReplacesSecretValuesAndKeepsByteCount() {
        let entry = makeEntry(attributes: [
            KeychainDumpAttribute(label: "Account", rawKey: "acct", value: "encamera"),
            KeychainDumpAttribute(label: "Value Data", rawKey: "v_Data", value: "0xdeadbeef…  (32 bytes)"),
            KeychainDumpAttribute(label: "Generic", rawKey: "gena", value: "top-secret-blob")
        ])

        let markdown = KeychainDumpMarkdown.markdown(for: entry, redacted: true)

        XCTAssertFalse(markdown.contains("deadbeef"))
        XCTAssertFalse(markdown.contains("top-secret-blob"))
        XCTAssertTrue(markdown.contains("| Value Data | v_Data | (redacted · 32 bytes) |"))
        XCTAssertTrue(markdown.contains("| Generic | gena | (redacted) |"))
        XCTAssertTrue(markdown.contains("| Account | acct | encamera |"), "Metadata must survive redaction")
    }

    func testUnredactedCopyKeepsSecretValues() {
        let entry = makeEntry(attributes: [
            KeychainDumpAttribute(label: "Value Data", rawKey: "v_Data", value: "hunter2  (7 bytes)")
        ])

        let markdown = KeychainDumpMarkdown.markdown(for: entry, redacted: false)

        XCTAssertTrue(markdown.contains("| Value Data | v_Data | hunter2  (7 bytes) |"))
    }

    func testMultiEntryDumpHasHeaderCountAndAllSections() {
        let entries = [
            makeEntry(itemClass: "Key", displayName: "encamera_default_key", attributes: []),
            makeEntry(itemClass: "Generic Password", displayName: "encamera", isSynchronizable: true, attributes: [])
        ]

        let markdown = KeychainDumpMarkdown.markdown(for: entries, redacted: true)

        XCTAssertTrue(markdown.hasPrefix("# Keychain Dump\n"))
        XCTAssertTrue(markdown.contains("2 items · redacted — secret values removed"))
        XCTAssertTrue(markdown.contains("## Key · encamera_default_key"))
        XCTAssertTrue(markdown.contains("## Generic Password · encamera (iCloud synced)"))
    }

    func testFullDumpHeaderSaysFullValues() {
        let markdown = KeychainDumpMarkdown.markdown(for: [makeEntry(attributes: [])], redacted: false)

        XCTAssertTrue(markdown.contains("1 item · full values"))
    }

    func testTableCellsEscapePipesAndNewlines() {
        let entry = makeEntry(attributes: [
            KeychainDumpAttribute(label: "Label", rawKey: "labl", value: "line one\nline | two")
        ])

        let markdown = KeychainDumpMarkdown.markdown(for: entry, redacted: false)

        XCTAssertTrue(markdown.contains("| Label | labl | line one line \\| two |"))
    }
}
