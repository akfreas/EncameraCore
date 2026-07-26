//
//  DebugPrintable.swift
//
//
//  Created by Alexander Freas on 21.12.23.
//

import Foundation
import os

public protocol DebugPrintable {

}

extension DebugPrintable {
    public static func printDebug(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let className = String(describing: Self.self)
        let message = items.map { "\($0)" }.joined(separator: separator)
        emitDebug(className: className, message: message, terminator: terminator)
    }

    public func printDebug(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        // Don't forward to the static overload: re-passing the variadic array
        // wraps it as a single element, and `type(of:)` on the metatype yields
        // a "Foo.Type" prefix instead of "Foo".
        let className = String(describing: type(of: self))
        let message = items.map { "\($0)" }.joined(separator: separator)
        emitDebug(className: className, message: message, terminator: terminator)
    }
}

/// Writes one debug line to the in-memory capture buffer, stdout, and the
/// unified log.
///
/// `debugPrint` alone is invisible on a real device: iOS discards a process's
/// stdout unless a debugger is attached, so logs added for on-device diagnosis
/// could only ever be read from Xcode. Mirroring to `os_log` means the same line
/// is readable with Console.app or `log stream --predicate 'subsystem ==
/// "me.freas.encamera"'` against a device running a detached build — which is
/// how a failing migration or sync actually gets diagnosed in the field.
///
/// The two external sinks are DEBUG-only on purpose. These messages are verbose
/// and describe an encryption app's internal operations; shipping them to the
/// unified log on user devices would be a privacy regression.
///
/// The in-memory capture below is the one exception, and it is deliberately not
/// `#if DEBUG`:
///
/// | sink                          | DEBUG            | Release          |
/// |-------------------------------|------------------|------------------|
/// | `debugPrint` → stdout         | yes              | no               |
/// | `os_log` → unified log        | yes              | no               |
/// | in-memory ring buffer         | when toggle on   | when toggle on   |
///
/// The privacy property that motivated the original `#if DEBUG` — internals
/// never reaching the *unified log*, which is an off-process, sysdiagnose-capturable
/// sink — is preserved exactly. `DebugLogBuffer` is process memory: opt-in behind
/// the `showDebugLogs` feature toggle, never persisted, cleared when the toggle
/// is switched off, and only externalized when the user taps Copy or Share in the
/// viewer. Allowing it in release is what makes on-device diagnosis of a
/// TestFlight build possible at all, which a DEBUG-only buffer never could.
@inline(__always)
private func emitDebug(className: String, message: String, terminator: String) {
    // No-op (one uncontended lock) when the toggle is off. Note the string work
    // above already happens in release today, so this adds only a lock, a
    // `Date()` and an array store on the enabled path.
    DebugLogBuffer.shared.record(category: className, message: message)

    #if DEBUG
    debugPrint("\(className): \(message)", terminator: terminator)
    // `.public` because the interpolated string is assembled by the caller and
    // would otherwise be redacted to `<private>` in the unified log, making the
    // device-readable copy useless.
    Logger(subsystem: DebugLog.subsystem, category: className)
        .debug("\(message, privacy: .public)")
    #endif
}

public enum DebugLog {
    /// Subsystem for every `printDebug` line, so a device log capture can be
    /// filtered to just this app:
    /// `log stream --predicate 'subsystem == "me.freas.encamera"'`
    public static let subsystem = "me.freas.encamera"
}
