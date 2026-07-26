//
//  DebugLogBuffer.swift
//  EncameraCore
//
//  Created by Alexander Freas on 26.07.26.
//

import Foundation

// MARK: - Entry

/// A single captured `printDebug` line.
public struct DebugLogEntry: Identifiable, Sendable, Hashable {

    /// Monotonic sequence number, not a UUID: it doubles as the lifetime
    /// "recorded" counter and makes ordering assertions trivial in tests.
    public let id: UInt64
    public let timestamp: Date
    /// The class name `printDebug` derived from the caller.
    public let category: String
    public let message: String
    /// Advisory only. Under Swift concurrency a `@MainActor` function can be
    /// observed running on a cooperative thread, so treat this as a hint about
    /// where the line came from rather than a guarantee.
    public let isMainThread: Bool

    public init(id: UInt64, timestamp: Date, category: String, message: String, isMainThread: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.isMainThread = isMainThread
    }

    /// Rough retained size, used only to enforce the buffer's byte budget.
    /// The constant covers the struct's own fields (two String headers, a Date,
    /// a UInt64 and a Bool); precision doesn't matter, only that a pathological
    /// run of huge messages is bounded.
    var approximateByteCount: Int {
        category.utf8.count + message.utf8.count + 48
    }
}

// MARK: - Stats

/// A consistent point-in-time read of the buffer's counters, so the UI can show
/// retained/recorded/evicted without taking the lock four separate times.
public struct DebugLogStats: Sendable, Equatable {

    /// Entries currently held in the ring.
    public let retained: Int
    /// Lifetime count of lines accepted since process start.
    public let totalRecorded: UInt64
    /// Lifetime count of lines dropped to stay within the capacity/byte bounds.
    public let evicted: UInt64
    public let isCapturing: Bool

    public init(retained: Int, totalRecorded: UInt64, evicted: UInt64, isCapturing: Bool) {
        self.retained = retained
        self.totalRecorded = totalRecorded
        self.evicted = evicted
        self.isCapturing = isCapturing
    }

    public static let empty = DebugLogStats(retained: 0, totalRecorded: 0, evicted: 0, isCapturing: false)
}

// MARK: - Buffer

/// In-memory ring buffer of `printDebug` output, fed from `emitDebug` in
/// `DebugPrintable.swift` and read by the in-app Debug Logs viewer.
///
/// Capture is opt-in behind the `showDebugLogs` feature toggle and is a no-op
/// (one uncontended lock) when that toggle is off. Nothing here is ever
/// persisted: the buffer lives and dies with the process, is cleared when the
/// toggle is switched off, and only leaves the app when the user explicitly
/// taps Copy or Share in the viewer.
///
/// Unlike `DebugTrackingStore`, this is deliberately **not** `@MainActor`.
/// `printDebug` is called from actors (`DiskFileAccess`, `EncryptedMetadataHandler`,
/// `CameraConfigurationService`), from value types, and from arbitrary threads;
/// forcing a main-actor hop per line would be both a correctness hazard and a
/// throughput problem in hot import loops. Hence `NSLock` + `@unchecked Sendable`,
/// which is the established pattern in this module (see `DeviceIDProvider`,
/// `CloudKitAlbumTombstoneQueue`).
///
/// - Important: This type must never conform to `DebugPrintable` and must never
///   call `printDebug`, directly or transitively. `NSLock` is not recursive, so
///   a log line emitted from inside the lock would deadlock the calling thread —
///   and since `printDebug` runs on essentially every code path, that means the
///   app. This is why the feature-toggle read in `resolveIfNeeded()` happens
///   outside the lock rather than inside it.
public final class DebugLogBuffer: @unchecked Sendable {

    public static let shared = DebugLogBuffer()

    /// 8x `DebugTrackingStore`'s 500-event cap: log lines are far more
    /// voluminous than analytics events (461 `printDebug` call sites, 62 in
    /// `MediaImportHandler` alone).
    public static let capacity = 4_000

    /// Per-message cap. A few callers dump whole metadata blobs; without this a
    /// handful of lines could dominate the buffer.
    public static let maxMessageCharacters = 2_000

    /// The real backstop. `capacity * maxMessageCharacters` is ~16 MB worst
    /// case, which is not acceptable in an app that also holds decrypted media
    /// in memory, so entries are evicted once the retained payload exceeds this.
    public static let byteBudget = 4 * 1024 * 1024

    private let lock = NSLock()

    // MARK: State — every property below is guarded by `lock`

    /// Pre-allocated and fixed-size, so append and evict are both O(1) and the
    /// array never reallocates. (`DebugTrackingStore` uses `insert(at: 0)` +
    /// `removeLast`, which is O(n) per line — fine for 500 events, not for this.)
    private var storage: [DebugLogEntry?]
    /// Index of the oldest retained entry.
    private var head = 0
    private var count = 0
    private var approximateBytes = 0
    /// Next id to hand out; also the lifetime "recorded" count.
    private var nextID: UInt64 = 0
    private var evictedCount: UInt64 = 0
    /// Bumped on every mutation. The viewer polls this and re-snapshots only
    /// when it changes, which keeps SwiftUI diffs bounded no matter how fast
    /// lines arrive.
    private var generationValue: UInt64 = 0
    private var capturing = false
    /// Whether the feature toggle has been read yet in this process.
    private var didResolveInitialState = false

    init(capacity: Int = DebugLogBuffer.capacity) {
        storage = [DebugLogEntry?](repeating: nil, count: max(1, capacity))
    }

    // MARK: - Hot path

    /// Records one line. Safe to call from any thread or actor.
    ///
    /// When capture is off this costs a single uncontended lock/unlock and
    /// returns; no `Date()`, no allocation, no string work beyond what the
    /// caller already did.
    public func record(category: String, message: String) {
        // 1. Cheap gate.
        lock.lock()
        var enabled = capturing
        let resolved = didResolveInitialState
        lock.unlock()

        // 2. First call in the process reads the toggle, outside the lock.
        if !resolved {
            resolveIfNeeded()
            lock.lock()
            enabled = capturing
            lock.unlock()
        }
        guard enabled else { return }

        // 3. Build the entry outside the lock.
        let timestamp = Date()
        let trimmed = Self.truncate(message)
        let isMain = Thread.isMainThread

        // 4. Short critical section: id, insert, generation bump.
        lock.lock()
        defer { lock.unlock() }
        guard capturing else { return }
        let entry = DebugLogEntry(
            id: nextID,
            timestamp: timestamp,
            category: category,
            message: trimmed,
            isMainThread: isMain
        )
        nextID &+= 1
        appendLocked(entry)
        generationValue &+= 1
    }

    // MARK: - Capture gate

    public var isCapturing: Bool {
        resolveIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return capturing
    }

    /// Turns capture on or off. Switching it **off also clears** whatever was
    /// collected, so disabling the toggle drops the data immediately rather than
    /// leaving it in memory until the app is quit.
    public func setCapturing(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        didResolveInitialState = true
        capturing = enabled
        if !enabled {
            clearLocked()
        }
        // Bump unconditionally so an open viewer notices the state change.
        generationValue &+= 1
    }

    /// Mirrors the current `showDebugLogs` toggle value into the buffer.
    ///
    /// Not required at launch — `record` resolves lazily on first use, so lines
    /// emitted before app-delegate setup are still captured — but useful for
    /// tests and for forcing a re-read.
    public func refreshFromFeatureToggle() {
        setCapturing(FeatureToggle.isEnabled(feature: .showDebugLogs))
    }

    /// Reads the toggle once per process, deliberately **not** holding the lock
    /// while touching `UserDefaults` (see the type-level deadlock note).
    private func resolveIfNeeded() {
        lock.lock()
        let resolved = didResolveInitialState
        lock.unlock()
        guard !resolved else { return }

        let value = FeatureToggle.isEnabled(feature: .showDebugLogs)

        lock.lock()
        if !didResolveInitialState {
            didResolveInitialState = true
            capturing = value
        }
        lock.unlock()
    }

    // MARK: - Reads

    /// Monotonic mutation counter. Cheap enough to poll.
    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    public var stats: DebugLogStats {
        resolveIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return DebugLogStats(
            retained: count,
            totalRecorded: nextID,
            evicted: evictedCount,
            isCapturing: capturing
        )
    }

    /// - Parameter newestFirst: `true` for display order (new lines appear at
    ///   the top and never push content out from under the reader), `false` for
    ///   chronological order, which is what a text export wants.
    public func snapshot(newestFirst: Bool = true) -> [DebugLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        var result: [DebugLogEntry] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            if let entry = storage[(head + offset) % storage.count] {
                result.append(entry)
            }
        }
        if newestFirst {
            result.reverse()
        }
        return result
    }

    /// Drops all retained entries. Lifetime counters (`totalRecorded`,
    /// `evicted`) are preserved so the footer keeps telling the truth about how
    /// much traffic there has been.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        clearLocked()
        generationValue &+= 1
    }

    // MARK: - Locked helpers

    private func appendLocked(_ entry: DebugLogEntry) {
        if count == storage.count {
            evictOldestLocked()
        }
        storage[(head + count) % storage.count] = entry
        count += 1
        approximateBytes += entry.approximateByteCount

        // Keep at least one entry so a single oversized line is still visible.
        while approximateBytes > Self.byteBudget, count > 1 {
            evictOldestLocked()
        }
    }

    private func evictOldestLocked() {
        guard count > 0, let evicted = storage[head] else { return }
        approximateBytes -= evicted.approximateByteCount
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        evictedCount &+= 1
    }

    private func clearLocked() {
        for index in storage.indices {
            storage[index] = nil
        }
        head = 0
        count = 0
        approximateBytes = 0
    }

    // MARK: - Truncation

    static func truncate(_ message: String) -> String {
        // UTF-8 is String's native storage, so `utf8.count` is O(1) while
        // `count` has to walk grapheme breaks. Byte count is always >= character
        // count, so this cheaply clears the overwhelmingly common short-message
        // case without ever doing the O(n) work on the hot path.
        guard message.utf8.count > maxMessageCharacters else { return message }
        guard message.count > maxMessageCharacters else { return message }
        let dropped = message.count - maxMessageCharacters
        let kept = message.prefix(maxMessageCharacters)
        return "\(kept)… [truncated \(dropped) chars]"
    }
}
