import Foundation

/// A `UserDefaults` suite that is genuinely empty at every call site.
///
/// A suite named after the test and cleared with `removePersistentDomain(forName:)`
/// is not enough: called on an instance that already has the domain loaded, it leaves
/// the loaded values in place, and the suite is persisted to
/// `<device>/data/Library/Preferences/<suite>.plist`, so whatever a previous test
/// *process* wrote comes back on the next run. The per-call UUID avoids that — a
/// suite that has never existed cannot carry state. `label` is carried only to keep
/// the on-disk plists identifiable while debugging.
func makeIsolatedDefaults(_ label: String = #function) -> UserDefaults {
    defaults(forSuite: makeIsolatedSuiteName(label))
}

/// The suite name on its own, for a call site that cannot capture a `UserDefaults`
/// (it is not `Sendable`, so a `@Sendable` closure has to build its own instance
/// from the name).
func makeIsolatedSuiteName(_ label: String = #function) -> String {
    "test.isolated.\(label.replacingOccurrences(of: "()", with: "")).\(UUID().uuidString)"
}

func defaults(forSuite suite: String) -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: suite) else {
        fatalError("Could not create an isolated defaults suite named \(suite)")
    }
    return defaults
}
