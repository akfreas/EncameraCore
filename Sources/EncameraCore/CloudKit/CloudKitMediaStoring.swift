//
//  CloudKitMediaStoring.swift
//  EncameraCore
//
//  The protocol seam for the Option-A CloudKit record store, plus its value
//  types. Everything downstream (sync coordinator, storage backend, migration,
//  UI, and their tests) depends on this interface — never on CloudKit directly.
//  See plans/cloudkit-migration/02-cloudkit-media-store.md.
//

import Foundation
import CloudKit

// MARK: - Value types

/// One media item to upload as a single `EncMedia` record. The two URLs point at
/// the *already encrypted* on-disk files — only ciphertext ever reaches CloudKit.
public struct CloudKitMediaUpload: Sendable {
    public let albumID: String          // hashPrimaryKey(albumName) — deterministic, non-reversible
    /// The CloudKit record name — UNIQUE per blob. A Live Photo's photo and video
    /// components share a `mediaID` but must be distinct records, or the second
    /// upload overwrites the first. Defaults to `mediaID` for single-component media.
    public let recordName: String
    public let mediaID: String          // shared grouping id (the InteractableMedia id)
    public let mediaType: MediaType
    public let createdAt: Date
    public let sizeBytes: Int64
    public let encryptedFileURL: URL     // full ENC2 ciphertext -> encBlob (lazy)
    /// Small encrypted preview -> encThumbnail (eager). Optional: if preview
    /// generation failed there is no file, and uploading a missing asset would fail
    /// the whole record — so the eager thumbnail is simply omitted in that case.
    public let encryptedThumbURL: URL?
    public let schemaVersion: Int64
    /// `PrivateKey.keychainLabel` of the key that produced `encryptedFileURL` —
    /// lowercase hex of the full 16-byte fingerprint. Empty means "unknown"; the
    /// record is then written without the field (see
    /// `CloudKitSchema.EncMedia.keyFingerprint`).
    public let keyFingerprint: String

    public init(albumID: String,
                mediaID: String,
                mediaType: MediaType,
                createdAt: Date,
                sizeBytes: Int64,
                encryptedFileURL: URL,
                encryptedThumbURL: URL?,
                recordName: String? = nil,
                keyFingerprint: String = "",
                schemaVersion: Int64 = CloudKitSchema.currentSchemaVersion) {
        self.keyFingerprint = keyFingerprint
        self.albumID = albumID
        self.mediaID = mediaID
        self.recordName = recordName ?? mediaID
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.encryptedFileURL = encryptedFileURL
        self.encryptedThumbURL = encryptedThumbURL
        self.schemaVersion = schemaVersion
    }
}

/// Asset-free index fields for one record — cheap to sync for the whole gallery.
public struct CloudKitMediaMetadata: Sendable, Equatable {
    public let recordName: String
    public let albumID: String
    public let mediaID: String
    public let mediaType: MediaType
    public let createdAt: Date
    public let sizeBytes: Int64
    public let creationDeviceID: String
    public let deletedAt: Date?
    public let schemaVersion: Int64
    public let recordChangeTag: String?

    public init(recordName: String,
                albumID: String,
                mediaID: String,
                mediaType: MediaType,
                createdAt: Date,
                sizeBytes: Int64,
                creationDeviceID: String,
                deletedAt: Date?,
                schemaVersion: Int64,
                recordChangeTag: String?) {
        self.recordName = recordName
        self.albumID = albumID
        self.mediaID = mediaID
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.creationDeviceID = creationDeviceID
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
        self.recordChangeTag = recordChangeTag
    }
}

/// Lightweight reference returned after a save.
public struct CloudKitMediaRef: Sendable, Equatable {
    public let recordName: String
    public let recordChangeTag: String?

    public init(recordName: String, recordChangeTag: String?) {
        self.recordName = recordName
        self.recordChangeTag = recordChangeTag
    }
}

/// One album to upsert as a single `EncAlbum` record (chunk 13). `albumID` is the
/// keyed hash of the album name — it is BOTH the record name and the value media
/// records carry in `EncMedia.albumID`, so the join needs no separate identifier.
public struct CloudKitAlbumUpload: Sendable {
    public let albumID: String          // record name == keyedHash(name, key)
    public let encName: String          // album-name ciphertext (Album.encryptedPathComponent)
    public let createdAt: Date
    public let isHidden: Bool
    public let schemaVersion: Int64
    /// `PrivateKey.keychainLabel` of the album's key. Empty means "unknown" and the
    /// field is then left off the record entirely.
    public let keyFingerprint: String

    public init(albumID: String,
                encName: String,
                createdAt: Date,
                isHidden: Bool,
                keyFingerprint: String = "",
                schemaVersion: Int64 = CloudKitSchema.currentSchemaVersion) {
        self.keyFingerprint = keyFingerprint
        self.albumID = albumID
        self.encName = encName
        self.createdAt = createdAt
        self.isHidden = isHidden
        self.schemaVersion = schemaVersion
    }
}

/// An album record as fetched from CloudKit. `deletedAt != nil` is a cross-device
/// tombstone (the album was deleted on another device).
public struct CloudKitAlbumMetadata: Sendable, Equatable {
    public let albumID: String          // == record name
    public let encName: String
    public let createdAt: Date
    public let isHidden: Bool
    public let deletedAt: Date?
    public let schemaVersion: Int64
    /// `EncAlbum.keyFingerprint` as read back from the record — the key this
    /// album's media is encrypted under, answerable even when the album has no
    /// live media. `nil` means the record predates the field ("unknown", never
    /// "no key").
    public let keyFingerprint: String?
    public let recordChangeTag: String?

    public init(albumID: String,
                encName: String,
                createdAt: Date,
                isHidden: Bool,
                deletedAt: Date?,
                schemaVersion: Int64,
                keyFingerprint: String?,
                recordChangeTag: String?) {
        self.albumID = albumID
        self.encName = encName
        self.createdAt = createdAt
        self.isHidden = isHidden
        self.deletedAt = deletedAt
        self.schemaVersion = schemaVersion
        self.keyFingerprint = keyFingerprint
        self.recordChangeTag = recordChangeTag
    }
}

/// The result of a delta sync since a server change token.
public struct CloudKitChangeSet: Sendable {
    public let changed: [CloudKitMediaMetadata]
    public let deleted: [String]            // record names
    public let token: CKServerChangeToken?
    public let moreComing: Bool

    public init(changed: [CloudKitMediaMetadata],
                deleted: [String],
                token: CKServerChangeToken?,
                moreComing: Bool) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

// MARK: - Protocol

public protocol CloudKitMediaStoring: Sendable {
    /// Upload one item as a single record carrying both assets and the index fields.
    func upload(_ item: CloudKitMediaUpload,
                progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef

    /// Cheap metadata sync for an album. Asset fields are excluded via `desiredKeys`;
    /// `includeThumbnail` additionally requests the small eager thumbnail key (never
    /// the full blob). Tombstoned records are filtered out.
    func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata]

    /// Strongly-consistent existence check for ONE record by name: a fetch-by-record-ID
    /// (`CKFetchRecordsOperation`), NOT the eventually-consistent `fetchMetadata` query,
    /// so a just-saved record is reliably visible immediately. Returns the record's
    /// metadata, or `nil` if the server has no such (non-tombstoned) record. This is the
    /// gate migration uses before deleting a local original.
    func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata?

    /// Lazy full fetch: download the `encBlob` asset for one record, copied to `destination`.
    func fetchBlob(recordName: String,
                   to destination: URL,
                   progress: @escaping @Sendable (Double) -> Void) async throws

    /// Lazy eager-thumb fetch: download the `encThumbnail` asset, copied to `destination`.
    func fetchThumbnail(recordName: String, to destination: URL) async throws

    /// Hard delete: removes the record and (atomically) both assets.
    func delete(recordName: String) async throws

    /// Soft delete: set `deletedAt` for cross-device delete propagation (chunk 03).
    func tombstone(recordName: String) async throws

    // MARK: Albums (chunk 13)

    /// Upsert one `EncAlbum` record so the album syncs across devices. Idempotent:
    /// the record name is the album-id hash, so re-saving the same album is a no-op
    /// upsert. Clears any prior `deletedAt` so re-creating a deleted album revives it.
    func saveAlbum(_ album: CloudKitAlbumUpload) async throws

    /// Fetch every `EncAlbum` record in the zone, INCLUDING tombstoned ones — the
    /// caller needs tombstones to remove locally-materialized albums. Album discovery
    /// is a full query (albums are few), not a delta sync, so it is independent of the
    /// per-album media change-token cursor.
    func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata]

    /// A zone-wide census of live (non-tombstoned) `EncMedia` records: how many there
    /// are, and how many name each key fingerprint. A metadata-only query over the
    /// indexed `keyFingerprint` field — it must not fetch a blob or a thumbnail.
    ///
    /// Records written before the field existed are absent from `fingerprints`:
    /// missing means "unknown", not "no key", and the caller falls back to the
    /// existing `KeyDiscovery` sweep for them. `mediaCount` still counts them, so
    /// "records exist but none names a key" stays distinguishable from "no records
    /// at all".
    ///
    /// Returns `.indexUnavailable` rather than throwing when the field is not yet
    /// queryable server-side.
    func fetchFingerprintCensus() async throws -> CloudKitFingerprintCensus

    /// Soft-delete an album (set `deletedAt`). `.deleteSelf` references on its media
    /// cascade server-side; the per-media tombstone path remains the cross-device
    /// backstop. No-op if the album record is absent.
    func tombstoneAlbum(albumID: String) async throws

    /// Delta sync: changes since `token` (nil == full sync) plus the new token. Pure —
    /// it does NOT persist the token, so the caller can commit it only after durably
    /// applying the changes (otherwise a mid-sync failure loses those changes forever).
    func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet

    /// The last committed zone change token (the resume point for the next sync).
    func loadChangeToken() async -> CKServerChangeToken?

    /// Whether a change token is currently persisted. Lets the coordinator detect a
    /// wiped index while a token still exists (which must force a full resync).
    func hasChangeToken() async -> Bool

    /// Persist the zone change token. Call only after the changes it covers are saved.
    func commitChangeToken(_ token: CKServerChangeToken?) async

    /// Discard the stored change token (after `changeTokenExpired`) so the next sync
    /// starts from scratch.
    func resetChangeToken() async

    /// Force-recreate the custom zone (after `zoneNotFound`): clears the cached
    /// "zone created" flag and re-issues the create.
    func recreateZone() async throws

    /// Idempotently ensure the custom record zone exists before any record I/O.
    /// Routed through the store so tests/mocks never touch a live container.
    func ensureZoneExists() async throws

    /// Idempotently register the zone push subscription (silent content-available)
    /// so other devices' changes arrive by push. No-op when the account is missing.
    func registerZoneSubscription() async throws

    /// Best-effort cancellation of in-flight operations.
    func cancelAll()

    /// Whether the CloudKit account is usable (else the caller stays local-only).
    func accountAvailable() async -> Bool
}

// MARK: - Fingerprint census

/// The outcome of the zone-wide `keyFingerprint` query, keeping "queried
/// successfully, genuinely zero" separate from "the index is not available, so
/// this signal tells you nothing".
public enum CloudKitFingerprintCensus: Sendable, Equatable {
    /// The query ran. `mediaCount` is every live `EncMedia` record in the zone;
    /// `fingerprints` maps fingerprint hex -> count for the subset that names a
    /// key. `mediaCount` can exceed the summed fingerprint counts when records
    /// predate the field, so `.counted(mediaCount: 0, fingerprints: [:])` means
    /// the account genuinely has no CloudKit media.
    case counted(mediaCount: Int, fingerprints: [String: Int])

    /// The server schema cannot answer the census query yet — the `EncMedia`
    /// record type or its `createdAt` index has not been deployed to this
    /// container (see ENC-70). Carries no information in either direction;
    /// callers must treat it as unresolved, never as "no data".
    case indexUnavailable
}

