//
//  MediaStorageDetails.swift
//  EncameraCore
//
//  Where one media item's ciphertext physically lives, how big it is in each
//  place, and which container format holds it. Read-only: nothing here mutates
//  storage, so the info screen can ask freely.
//

import Foundation

/// Which on-disk encrypted container format a ciphertext file uses.
///
/// The three coexist by design — see `SeekableEncryptedFormat`'s header for why
/// ENC3 is an addition rather than a replacement — so a single album routinely
/// holds all three and the format is a per-file property, never a per-album one.
public enum EncryptedFormatVersion: Int, Sendable, Equatable, CaseIterable {
    /// No header at all: a bare `crypto_secretstream` stream. Everything written
    /// before the metadata section existed.
    case v1 = 1
    /// `ENC2`: encrypted metadata header followed by one sequential secretstream.
    case v2 = 2
    /// `ENC3`: independently-encrypted fixed-size chunks, so a video can be sought.
    case v3 = 3

    public var displayName: String {
        switch self {
        case .v1: return "ENC1"
        case .v2: return "ENC2"
        case .v3: return "ENC3"
        }
    }

    /// Classifies a file from its leading bytes.
    ///
    /// V1 carries no magic, so it is what remains once V2 and V3 are excluded.
    /// That is the same by-elimination rule `SecretFileHandler.setupDecryption`
    /// decrypts by, and it means `data` shorter than the magic is unclassifiable
    /// rather than V1 — an empty or truncated file names no format.
    public static func sniff(headerBytes data: Data) -> EncryptedFormatVersion? {
        guard data.count >= EncryptedFileFormat.magicSize else { return nil }
        let magic = Array(data.prefix(EncryptedFileFormat.magicSize))
        if magic == SeekableEncryptedHeader.magic { return .v3 }
        if magic == EncryptedFileFormat.magic { return .v2 }
        return .v1
    }

    /// Classifies the file at `fileURL`, reading only its first four bytes.
    /// `nil` when the file is absent, unreadable, or too short to classify.
    public static func sniff(fileURL: URL) -> EncryptedFormatVersion? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: EncryptedFileFormat.magicSize) else { return nil }
        return sniff(headerBytes: head)
    }
}

/// Where one media item's ciphertext lives and what it costs, per component.
///
/// A Live Photo is two files under one id, and the two can differ in every field
/// here — an ENC2 photo beside an ENC3 movie, one cached and one not — so the
/// per-component rows are the real answer and the whole-item aggregates below
/// are derived from them.
public struct MediaStorageDetails: Sendable, Equatable {

    /// One encrypted component of the item.
    public struct Component: Sendable, Equatable {
        public let mediaType: MediaType
        /// Ciphertext bytes the remote copy occupies. `nil` when the item has no
        /// remote copy (a local album) or when the size is not yet known.
        public let remoteBytes: Int64?
        /// Ciphertext bytes resident on *this device*: the album file for a local
        /// album, or the cached blob plus any cached ENC3 chunks for a cloud one.
        /// `nil` when nothing is resident — the distinction from `0` is what makes
        /// "not cached" different from "cached and empty".
        public let localBytes: Int64?
        /// `nil` when the format cannot be named without downloading the blob:
        /// a cloud component that is neither chunked (which the record states
        /// outright) nor cached (which we could sniff). Guessing ENC2 here would
        /// be wrong for the migrated ENC1 files that still exist.
        public let format: EncryptedFormatVersion?
        /// Chunks the blob splits into. Non-nil only for `.v3`.
        public let chunkCount: Int?

        public init(mediaType: MediaType,
                    remoteBytes: Int64?,
                    localBytes: Int64?,
                    format: EncryptedFormatVersion?,
                    chunkCount: Int?) {
            self.mediaType = mediaType
            self.remoteBytes = remoteBytes
            self.localBytes = localBytes
            self.format = format
            self.chunkCount = chunkCount
        }
    }

    public let storageType: StorageType
    public let components: [Component]

    public init(storageType: StorageType, components: [Component]) {
        self.storageType = storageType
        self.components = components
    }

    /// Whether the bytes have a home off this device. False only for `.local`,
    /// where "remote size" and "cached copy" are both meaningless.
    public var isRemotelyBacked: Bool {
        storageType != .local
    }

    /// Bytes held remotely across every component, or `nil` when no component
    /// reports one.
    public var remoteBytes: Int64? {
        sum(\.remoteBytes)
    }

    /// Bytes resident on this device across every component, or `nil` when none is.
    public var localBytes: Int64? {
        sum(\.localBytes)
    }

    /// The format shared by every component that names one, or `nil` when they
    /// disagree or none is known. A Live Photo whose photo is ENC2 and whose movie
    /// is ENC3 deliberately reports `nil` rather than picking a winner.
    public var format: EncryptedFormatVersion? {
        let known = Set(components.compactMap(\.format))
        return known.count == 1 ? known.first : nil
    }

    /// Chunks across every chunked component, or `nil` when none is chunked.
    public var chunkCount: Int? {
        let counts = components.compactMap(\.chunkCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    /// Whether there is a re-downloadable local copy worth removing. False for a
    /// local album (removing it would be deletion, not eviction) and for a cloud
    /// item that holds nothing locally.
    public var canEvictLocalCopy: Bool {
        isRemotelyBacked && (localBytes ?? 0) > 0
    }

    private func sum(_ path: KeyPath<Component, Int64?>) -> Int64? {
        let values = components.compactMap { $0[keyPath: path] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}
