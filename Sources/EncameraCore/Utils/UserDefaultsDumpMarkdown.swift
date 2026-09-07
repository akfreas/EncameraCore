//
//  UserDefaultsDumpMarkdown.swift
//  Encamera
//
//  Renders UserDefaults inspector dumps as Markdown for clipboard sharing.
//

import Foundation

public enum UserDefaultsDumpMarkdown {

    public static func markdown(for entries: [UserDefaultsDumpEntry], redacted: Bool) -> String {
        var lines = ["# UserDefaults Dump", ""]
        let mode = redacted ? "redacted — values removed" : "full values"
        lines.append("\(entries.count) key\(entries.count == 1 ? "" : "s") · \(mode)")
        for entry in entries {
            lines.append("")
            lines.append(markdown(for: entry, redacted: redacted))
        }
        return lines.joined(separator: "\n")
    }

    public static func markdown(for entry: UserDefaultsDumpEntry, redacted: Bool) -> String {
        var lines: [String] = []
        let cloudSuffix = entry.isInCloudStore ? " (iCloud synced)" : ""
        lines.append("## \(escapeCell(entry.key))\(cloudSuffix)")
        lines.append("")
        lines.append("| Attribute | Value |")
        lines.append("| --- | --- |")
        for attribute in entry.attributes {
            let value: String
            if redacted && attribute.label.contains("Value") {
                value = "(redacted)"
            } else {
                value = attribute.value
            }
            lines.append("| \(escapeCell(attribute.label)) | \(escapeCell(value)) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func escapeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
