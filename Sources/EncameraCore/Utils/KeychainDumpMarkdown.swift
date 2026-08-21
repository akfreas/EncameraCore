//
//  KeychainDumpMarkdown.swift
//  Encamera
//
//  Renders keychain-inspector dumps as Markdown for sharing via the clipboard.
//

import Foundation
import Security

/// Formats `KeychainDumpEntry` values as Markdown so the debug keychain
/// inspector can copy a readable dump — of one item or the whole keychain —
/// to the clipboard. The redacted variant keeps every attribute row but
/// replaces the values that carry secret material (`v_Data`, refs, the
/// app-private generic blob), so it is safe to paste into chats and tickets.
public enum KeychainDumpMarkdown {

    /// Raw attribute keys whose values contain the item's secret material (or
    /// an opaque blob that may) rather than metadata about it.
    private static let sensitiveRawKeys: Set<String> = [
        kSecValueData as String,
        kSecValueRef as String,
        kSecValuePersistentRef as String,
        kSecAttrGeneric as String
    ]

    public static func markdown(for entries: [KeychainDumpEntry], redacted: Bool) -> String {
        var lines = ["# Keychain Dump", ""]
        let mode = redacted ? "redacted — secret values removed" : "full values"
        lines.append("\(entries.count) item\(entries.count == 1 ? "" : "s") · \(mode)")
        for entry in entries {
            lines.append("")
            lines.append(markdown(for: entry, redacted: redacted))
        }
        return lines.joined(separator: "\n")
    }

    public static func markdown(for entry: KeychainDumpEntry, redacted: Bool) -> String {
        var lines: [String] = []
        let syncSuffix = entry.isSynchronizable ? " (iCloud synced)" : ""
        lines.append("## \(entry.itemClass) · \(escapeCell(entry.displayName))\(syncSuffix)")
        lines.append("")
        lines.append("| Attribute | Raw Key | Value |")
        lines.append("| --- | --- | --- |")
        for attribute in entry.attributes {
            let value = redacted && sensitiveRawKeys.contains(attribute.rawKey)
                ? redactedValue(replacing: attribute.value)
                : attribute.value
            lines.append("| \(escapeCell(attribute.label)) | \(escapeCell(attribute.rawKey)) | \(escapeCell(value)) |")
        }
        return lines.joined(separator: "\n")
    }

    /// Redacts a rendered attribute value, preserving the trailing byte count
    /// that `describeKeychainValue` appends ("… (32 bytes)") since the size of
    /// a secret is metadata worth keeping.
    private static func redactedValue(replacing value: String) -> String {
        if let range = value.range(of: #"\(\d+ bytes\)$"#, options: .regularExpression) {
            let byteCount = value[range].dropFirst().dropLast()
            return "(redacted · \(byteCount))"
        }
        return "(redacted)"
    }

    private static func escapeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
