//
//  DebugLogFormatter.swift
//  EncameraCore
//
//  Created by Alexander Freas on 26.07.26.
//

import Foundation

/// Turns captured log entries into the plain text used by the viewer's Copy and
/// Share actions.
///
/// Lives in EncameraCore rather than the app target so the serialization format
/// is unit-testable without standing up any UI.
public enum DebugLogFormatter {

    /// - Note: A fresh formatter per export, never a shared mutable static —
    ///   `DateFormatter` is not thread-safe, and the buffer is written from
    ///   arbitrary threads.
    public static func makeLineFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        // POSIX locale so the output is stable regardless of device region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }

    /// One entry as `2026-07-26 14:15:00.123  [main] DiskFileAccess: <message>`.
    ///
    /// Multi-line messages are written verbatim: the timestamp prefix already
    /// marks where each entry starts, and rewriting embedded newlines would
    /// corrupt the JSON and metadata dumps that some callers log.
    public static func line(for entry: DebugLogEntry, formatter: DateFormatter) -> String {
        let thread = entry.isMainThread ? "main" : "bg"
        return "\(formatter.string(from: entry.timestamp))  [\(thread)] \(entry.category): \(entry.message)"
    }

    /// Renders entries in the order given, optionally behind a header block.
    ///
    /// - Parameter entries: expected **oldest first** — a log file should read
    ///   top-down in time, even though the on-screen list is newest-first. The
    ///   caller is responsible for reversing the display order.
    public static func plainText(entries: [DebugLogEntry], header: String? = nil) -> String {
        let formatter = makeLineFormatter()
        var output = ""

        if let header, !header.isEmpty {
            output += header
            if !header.hasSuffix("\n") {
                output += "\n"
            }
        }

        for entry in entries {
            output += line(for: entry, formatter: formatter)
            output += "\n"
        }

        return output
    }
}
