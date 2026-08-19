//
//  MediaIndexEntry.swift
//  EncameraCore
//
//  A compact, sortable description of one media item. A list of these forms a
//  per-album media index so large albums can be opened and paged without
//  scanning or decrypting every encrypted file.
//

import Foundation

public enum MediaIndexError: Error {
    case corruptIndex
    case unsupportedVersion
    case encryptionFailed
    case decryptionFailed
}

/// One row of a per-album media index: the minimum needed to sort and filter a
/// media item without opening or decrypting its file. One entry corresponds to
/// one `InteractableMedia` — a Live Photo's photo and video components share a
/// single id and therefore a single entry.
public struct MediaIndexEntry: Equatable, Sendable {

    /// Media id — the shared filename stem of the underlying encrypted file(s).
    public let id: String
    /// Whether an `.encimage` file exists for this id.
    public let hasPhotoComponent: Bool
    /// Whether an `.encvideo` file exists for this id.
    public let hasVideoComponent: Bool
    /// When the media was encrypted/imported. `nil` for legacy files without metadata.
    public let dateEncrypted: Date?
    /// Original capture date from the encrypted metadata. `nil` if unknown.
    public let dateTaken: Date?
    /// Cached `MediaFilterOptions` raw value describing this single item
    /// (still image / screenshot / video / live photo).
    public let subtypeRawValue: Int

    public init(
        id: String,
        hasPhotoComponent: Bool,
        hasVideoComponent: Bool,
        dateEncrypted: Date?,
        dateTaken: Date?,
        subtypeRawValue: Int
    ) {
        self.id = id
        self.hasPhotoComponent = hasPhotoComponent
        self.hasVideoComponent = hasVideoComponent
        self.dateEncrypted = dateEncrypted
        self.dateTaken = dateTaken
        self.subtypeRawValue = subtypeRawValue
    }
}

public extension MediaIndexEntry {
    /// Combines this entry with another for the same media id, OR-ing the
    /// photo/video component flags so a Live Photo keeps both components, and
    /// keeping the first non-nil dates. The receiver's subtype wins. Used when a
    /// Live Photo's photo and video components are indexed separately (e.g. the
    /// video arriving after the photo) and must collapse into one entry.
    func merged(with other: MediaIndexEntry) -> MediaIndexEntry {
        MediaIndexEntry(
            id: id,
            hasPhotoComponent: hasPhotoComponent || other.hasPhotoComponent,
            hasVideoComponent: hasVideoComponent || other.hasVideoComponent,
            dateEncrypted: dateEncrypted ?? other.dateEncrypted,
            dateTaken: dateTaken ?? other.dateTaken,
            subtypeRawValue: subtypeRawValue
        )
    }
}

/// Parsing for component record names of the form `"mediaID#type"`, where
/// `type` is a `MediaType` raw value. A bare `"mediaID"` with no suffix names
/// a whole logical item. Centralized so every backend parses record names
/// identically.
public enum MediaRecordName {

    private static let separator = "#"

    /// The grouping id for a component record name (`"mediaID#type"` -> `"mediaID"`).
    public static func mediaID(from recordName: String) -> String {
        recordName.components(separatedBy: separator).first ?? recordName
    }

    /// Builds the record name for one component of a media item. The inverse of
    /// `parse`, kept beside it so the two cannot drift.
    public static func componentRecordName(mediaID: String, type: MediaType) -> String {
        "\(mediaID)\(separator)\(type.rawValue)"
    }

    /// The component `MediaType` a record name names, or `.unknown` when it
    /// carries no valid `"#type"` suffix. For callers that only ever have a
    /// record name to work from — notably a CloudKit zone-change deletion, whose
    /// payload is the record id and nothing else.
    public static func mediaType(from recordName: String) -> MediaType {
        parse(recordName).type ?? .unknown
    }

    /// Splits a record name into its media id and, when a valid `"#type"` suffix
    /// is present, the named component's `MediaType`. Anything that is not exactly
    /// `"mediaID#<valid-MediaType-raw-value>"` parses as `(id, nil)` — i.e. a
    /// whole-item reference.
    static func parse(_ recordName: String) -> (id: String, type: MediaType?) {
        let parts = recordName.components(separatedBy: separator)
        let id = parts.first ?? recordName
        guard parts.count == 2, let raw = Int(parts[1]), let type = MediaType(rawValue: raw) else {
            return (id, nil)
        }
        return (id, type)
    }
}

public extension Array where Element == MediaIndexEntry {
    /// Inserts `entry`, or merges it into the existing entry that shares its id.
    /// The single incremental-write primitive backends use to keep the
    /// index current as media is added. Returns whether the array actually
    /// changed — an idempotent re-upsert of an identical component reports `false`
    /// so callers (the mutation envelope, the coordinator's bus) can skip a no-op
    /// save or a redundant gallery refresh.
    @discardableResult
    mutating func upsert(_ entry: MediaIndexEntry) -> Bool {
        if let index = firstIndex(where: { $0.id == entry.id }) {
            let merged = self[index].merged(with: entry)
            guard merged != self[index] else { return false }
            self[index] = merged
            return true
        }
        append(entry)
        return true
    }

    /// Removes a single component identified by its record name (`"mediaID#type"`).
    /// For a Live Photo, only the named component's flag is cleared and the entry
    /// survives as long as the other component remains; the entry is removed once
    /// no component is left. A bare `"mediaID"` (no `#type`) removes the whole
    /// entry. Returns whether the entry was removed (`true`) versus merely having
    /// a component cleared (`false`); a record name with no matching entry counts
    /// as removed. The shared remove primitive for the per-component cloud path.
    @discardableResult
    mutating func removeComponent(recordName: String) -> Bool {
        let (id, type) = MediaRecordName.parse(recordName)
        guard let idx = firstIndex(where: { $0.id == id }) else { return true }

        // No component suffix => whole-item delete.
        guard let type else {
            remove(at: idx)
            return true
        }

        let existing = self[idx]
        let hasPhoto = existing.hasPhotoComponent && type != .photo
        let hasVideo = existing.hasVideoComponent && type != .video
        guard hasPhoto || hasVideo else {
            remove(at: idx)
            return true
        }
        self[idx] = MediaIndexEntry(id: existing.id,
                                    hasPhotoComponent: hasPhoto,
                                    hasVideoComponent: hasVideo,
                                    dateEncrypted: existing.dateEncrypted,
                                    dateTaken: existing.dateTaken,
                                    subtypeRawValue: existing.subtypeRawValue)
        return false
    }

    /// Removes every entry whose id is in `ids` — the disk delete/move fast path,
    /// where every component of a logical item is dropped together. Returns
    /// whether the index actually changed.
    @discardableResult
    mutating func removeEntries(ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        let before = count
        removeAll { ids.contains($0.id) }
        return count != before
    }
}

/// Compact binary serialization for a list of `MediaIndexEntry`. Decoding is a
/// single linear pass over the byte buffer — for 2000 entries this is well
/// under a millisecond, where `JSONDecoder` would take 5-30ms.
///
/// Layout (all multi-byte integers little-endian):
/// ```
///   magic        4 bytes  "EIX1"
///   version      UInt16
///   entryCount   UInt32
///   then `entryCount` records:
///     idLength       UInt8
///     id             idLength UTF-8 bytes
///     flags          UInt8   (bit0 hasPhoto, bit1 hasVideo)
///     subtype        UInt8   (MediaFilterOptions raw value)
///     dateEncrypted  UInt64  (Float64 bit pattern; NaN == nil)
///     dateTaken      UInt64  (Float64 bit pattern; NaN == nil)
/// ```
enum MediaIndexCodec {

    static let magic: [UInt8] = Array("EIX1".utf8)
    static let formatVersion: UInt16 = 1

    static func encode(_ entries: [MediaIndexEntry]) -> Data {
        var data = Data()
        data.reserveCapacity(10 + entries.count * 56)
        data.append(contentsOf: magic)
        data.appendLittleEndian(formatVersion)
        data.appendLittleEndian(UInt32(entries.count))
        for entry in entries {
            let idBytes = Array(entry.id.utf8.prefix(255))
            data.append(UInt8(idBytes.count))
            data.append(contentsOf: idBytes)
            var flags: UInt8 = 0
            if entry.hasPhotoComponent { flags |= 0b01 }
            if entry.hasVideoComponent { flags |= 0b10 }
            data.append(flags)
            data.append(UInt8(truncatingIfNeeded: entry.subtypeRawValue))
            data.appendLittleEndian(dateBitPattern(entry.dateEncrypted))
            data.appendLittleEndian(dateBitPattern(entry.dateTaken))
        }
        return data
    }

    static func decode(_ data: Data) throws -> [MediaIndexEntry] {
        var reader = BinaryReader(data)
        guard try reader.readByteArray(magic.count) == magic else {
            throw MediaIndexError.corruptIndex
        }
        guard try reader.readUInt16() == formatVersion else {
            throw MediaIndexError.unsupportedVersion
        }
        let count = try reader.readUInt32()
        var entries: [MediaIndexEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            let idLength = Int(try reader.readUInt8())
            let id = try reader.readString(idLength)
            let flags = try reader.readUInt8()
            let subtype = try reader.readUInt8()
            let dateEncrypted = dateFromBitPattern(try reader.readUInt64())
            let dateTaken = dateFromBitPattern(try reader.readUInt64())
            entries.append(MediaIndexEntry(
                id: id,
                hasPhotoComponent: flags & 0b01 != 0,
                hasVideoComponent: flags & 0b10 != 0,
                dateEncrypted: dateEncrypted,
                dateTaken: dateTaken,
                subtypeRawValue: Int(subtype)
            ))
        }
        return entries
    }

    /// Encodes an optional date as a `Float64` bit pattern; `nil` becomes `NaN`.
    private static func dateBitPattern(_ date: Date?) -> UInt64 {
        (date?.timeIntervalSinceReferenceDate ?? Double.nan).bitPattern
    }

    private static func dateFromBitPattern(_ bits: UInt64) -> Date? {
        let value = Double(bitPattern: bits)
        return value.isNaN ? nil : Date(timeIntervalSinceReferenceDate: value)
    }
}

// MARK: - Binary helpers

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

/// Minimal forward-only reader over a byte buffer. Integer reads index the
/// buffer directly — no per-read allocation — so decoding a large index stays
/// fast. Throws `corruptIndex` on any read that would run past the end.
private struct BinaryReader {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// Validates `count` bytes are available and returns the start offset,
    /// advancing the cursor past them.
    private mutating func advance(_ count: Int) throws -> Int {
        guard count >= 0, cursor + count <= bytes.count else {
            throw MediaIndexError.corruptIndex
        }
        let start = cursor
        cursor += count
        return start
    }

    mutating func readByteArray(_ count: Int) throws -> [UInt8] {
        let start = try advance(count)
        return Array(bytes[start..<start + count])
    }

    mutating func readString(_ count: Int) throws -> String {
        let start = try advance(count)
        return String(decoding: bytes[start..<start + count], as: UTF8.self)
    }

    mutating func readUInt8() throws -> UInt8 {
        bytes[try advance(1)]
    }

    mutating func readUInt16() throws -> UInt16 {
        let start = try advance(2)
        return UInt16(bytes[start]) | (UInt16(bytes[start + 1]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let start = try advance(4)
        var value: UInt32 = 0
        for offset in 0..<4 {
            value |= UInt32(bytes[start + offset]) << (8 * offset)
        }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let start = try advance(8)
        var value: UInt64 = 0
        for offset in 0..<8 {
            value |= UInt64(bytes[start + offset]) << UInt64(8 * offset)
        }
        return value
    }
}
