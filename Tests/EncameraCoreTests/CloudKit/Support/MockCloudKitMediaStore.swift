//
//  MockCloudKitMediaStore.swift
//  EncameraCoreTests
//
//  In-memory fake of the `CloudKitMediaStoring` seam for coordinator tests.
//

import Foundation
import CloudKit
@testable import EncameraCore

final class MockCloudKitMediaStore: CloudKitMediaStoring, @unchecked Sendable {

    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // Programmable
    var accountAvailableValue = true
    var changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
    var metadataToReturn: [CloudKitMediaMetadata] = []
    var blobContents = Data("ciphertext".utf8)
    var fetchBlobDelayNanos: UInt64 = 0
    /// Stalls `fetchFingerprintCensus` so a test can drive the onboarding probe
    /// past its time budget. `fetchBlobDelayNanos` cannot do that job: the probe
    /// never fetches a blob, which is the point of it.
    var fingerprintCensusDelayNanos: UInt64 = 0
    /// Forces the census answer, notably `.indexUnavailable` — the "queried but
    /// the server has not indexed `keyFingerprint` yet" case that must NOT read as
    /// "no data exists".
    var fingerprintCensusOverride: CloudKitFingerprintCensus?
    var fingerprintCensusError: Error?
    var fetchBlobError: Error?
    var fetchChangesError: Error?
    var deleteError: Error?
    /// The enumeration failures the destructive path must not mistake for "there
    /// was nothing here" (ENC-94). Without these hooks no test could reach that
    /// branch at all, which is how the vacuous-success bug survived.
    var fetchAllAlbumsError: Error?
    var fetchMetadataError: Error?
    var uploadRefOverride: CloudKitMediaRef?

    // Recorded
    private var _fetchBlobCount = 0
    private var _fingerprintCensusCount = 0
    var fingerprintCensusCount: Int { locked { _fingerprintCensusCount } }
    private var _fetchChangesCount = 0
    private var _registerSubscriptionCount = 0
    private var _tombstoneCalls: [String] = []
    private var _deleteCalls: [String] = []
    private var _uploadCalls: [String] = []
    private var _uploadedItems: [CloudKitMediaUpload] = []
    var uploadedItems: [CloudKitMediaUpload] { locked { _uploadedItems } }
    /// Records this mock believes made it onto the server and are not tombstoned,
    /// keyed by record name. Written only after `upload` clears its failure
    /// injections, and removed by `delete` / `tombstone` / `tombstoneAlbum` — so it
    /// models the live-record set the real store's census queries. `_uploadedItems`
    /// is a log of attempts and does neither.
    private var _liveRecords: [String: CloudKitMediaUpload] = [:]
    /// Blob bytes read at upload time, keyed by record name — the moment CloudKit
    /// would read the file. The holding-folder copy is deleted once the upload
    /// completes, so asserting on the file afterwards is impossible.
    private var _uploadedBlobBytes: [String: Data] = [:]
    var uploadedBlobBytes: [String: Data] { locked { _uploadedBlobBytes } }

    var fetchBlobCount: Int { locked { _fetchBlobCount } }
    var fetchChangesCount: Int { locked { _fetchChangesCount } }
    var registerSubscriptionCount: Int { locked { _registerSubscriptionCount } }
    var tombstoneCalls: [String] { locked { _tombstoneCalls } }
    var deleteCalls: [String] { locked { _deleteCalls } }
    var uploadCalls: [String] { locked { _uploadCalls } }

    var uploadErrorOnce: Error?
    /// Opt-in (default off): model CloudKit's parent-reference requirement. Every
    /// `EncMedia` record parents to its `EncAlbum` record, and the server rejects a
    /// save whose `parent` target does not already exist with `CKError 31`
    /// (reference violation), wrapped per-record in `.partial` by the real adapter.
    /// When set, `upload` fails that way unless `saveAlbum` ran first for the
    /// item's albumID.
    var enforceParentAlbumExists = false
    /// Opt-in (default off, so existing coordinator tests are unaffected): when set,
    /// each successful `upload` is reflected back from `fetchMetadata`, so a migration
    /// verify step sees what it just uploaded — modeling server truth.
    var reflectUploadsInMetadata = false
    private var _reflected: [CloudKitMediaMetadata] = []
    func upload(_ item: CloudKitMediaUpload,
                progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        let blobBytes = (try? Data(contentsOf: item.encryptedFileURL)) ?? Data()
        locked {
            _uploadCalls.append(item.mediaID)
            _uploadedItems.append(item)
            _uploadedBlobBytes[item.recordName] = blobBytes
        }
        if let error = uploadErrorOnce { uploadErrorOnce = nil; throw error }
        if enforceParentAlbumExists, locked({ _albums[item.albumID] == nil || _albums[item.albumID]?.deletedAt != nil }) {
            throw CloudKitMediaStoreError.partial(
                failed: [item.recordName: CKErrorFactory.error(.referenceViolation)]
            )
        }
        // Past every failure injection, so only a record that really "landed" counts.
        locked { _liveRecords[item.recordName] = item }
        if reflectUploadsInMetadata {
            locked {
                _reflected.removeAll { $0.recordName == item.recordName }
                _reflected.append(CloudKitMediaMetadata(
                    recordName: item.recordName,
                    albumID: item.albumID,
                    mediaID: item.mediaID,
                    mediaType: item.mediaType,
                    createdAt: item.createdAt,
                    sizeBytes: item.sizeBytes,
                    creationDeviceID: "mock",
                    deletedAt: nil,
                    schemaVersion: item.schemaVersion,
                    recordChangeTag: "tag-upload"
                ))
            }
        }
        progress(1.0)
        return uploadRefOverride ?? CloudKitMediaRef(recordName: item.recordName, recordChangeTag: "tag-upload")
    }

    func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata] {
        if let fetchMetadataError { throw fetchMetadataError }
        return locked { metadataToReturn + (reflectUploadsInMetadata ? _reflected : []) }
    }

    func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata? {
        locked { (metadataToReturn + (reflectUploadsInMetadata ? _reflected : []))
            .first { $0.recordName == recordName && $0.deletedAt == nil } }
    }

    /// Fractions reported, in order, before the fetch completes — each one
    /// `fetchBlobStepNanos` after the last. Models CloudKit's incremental
    /// `perRecordProgressBlock` so a test can act on a fetch it knows is
    /// genuinely mid-flight instead of guessing with sleeps.
    var fetchBlobProgressSteps: [Double] = []
    var fetchBlobStepNanos: UInt64 = 20_000_000
    /// Called (every time) as soon as a fetch reports its first fraction.
    var onFirstProgress: (@Sendable () -> Void)?
    private var _fetchBlobCancelledCount = 0
    /// How many fetches were stopped by task cancellation rather than finishing.
    var fetchBlobCancelledCount: Int { locked { _fetchBlobCancelledCount } }

    func fetchBlob(recordName: String,
                   to destination: URL,
                   progress: @escaping @Sendable (Double) -> Void) async throws {
        locked { _fetchBlobCount += 1 }
        do {
            for (index, fraction) in fetchBlobProgressSteps.enumerated() {
                try await Task.sleep(nanoseconds: fetchBlobStepNanos)
                progress(fraction)
                if index == 0 { onFirstProgress?() }
            }
            // Cancellation is honored here, unlike the old `try?` swallow: a
            // cancelled download must stop, not run to completion in the dark.
            if fetchBlobDelayNanos > 0 { try await Task.sleep(nanoseconds: fetchBlobDelayNanos) }
        } catch is CancellationError {
            locked { _fetchBlobCancelledCount += 1 }
            throw CancellationError()
        }
        if let fetchBlobError { throw fetchBlobError }
        try blobContents.write(to: destination)
        progress(1.0)
    }

    private(set) var fetchThumbnailCount = 0
    var fetchThumbnailWritesFile = true
    var fetchThumbnailError: Error?
    func fetchThumbnail(recordName: String, to destination: URL) async throws {
        locked { fetchThumbnailCount += 1 }
        if fetchThumbnailWritesFile { try blobContents.write(to: destination) }
        if let fetchThumbnailError { throw fetchThumbnailError }   // simulates a partial write then failure
    }

    func delete(recordName: String) async throws {
        locked { _deleteCalls.append(recordName) }
        if let deleteError { throw deleteError }
        locked { _liveRecords[recordName] = nil }
    }

    func tombstone(recordName: String) async throws {
        locked { _tombstoneCalls.append(recordName) }
        // Honors `deleteError` so a per-record tombstone failure can be injected
        // through the same seam as `delete`, which also records the call first.
        if let deleteError { throw deleteError }
        // A tombstoned record is no longer live, so it leaves the census — matching
        // the real store, which filters `deletedAt != nil` client-side.
        locked { _liveRecords[recordName] = nil }
    }

    // MARK: Albums (chunk 13)

    private var _albums: [String: CloudKitAlbumMetadata] = [:]
    private var _savedAlbumCalls: [CloudKitAlbumUpload] = []
    private var _tombstonedAlbumCalls: [String] = []
    var savedAlbumCalls: [CloudKitAlbumUpload] { locked { _savedAlbumCalls } }
    var tombstonedAlbumCalls: [String] { locked { _tombstonedAlbumCalls } }
    /// Seed album records as if they came from another device.
    func seedAlbum(_ album: CloudKitAlbumMetadata) { locked { _albums[album.albumID] = album } }

    var saveAlbumError: Error?
    func saveAlbum(_ album: CloudKitAlbumUpload) async throws {
        guard accountAvailableValue else { throw CloudKitMediaStoreError.accountUnavailable }
        if let saveAlbumError { throw saveAlbumError }
        locked {
            _savedAlbumCalls.append(album)
            _albums[album.albumID] = CloudKitAlbumMetadata(
                albumID: album.albumID, encName: album.encName, createdAt: album.createdAt,
                isHidden: album.isHidden, deletedAt: nil, schemaVersion: album.schemaVersion,
                keyFingerprint: album.keyFingerprint.isEmpty ? nil : album.keyFingerprint,
                recordChangeTag: "albumtag")
        }
    }

    private var _fetchAllAlbumsCount = 0
    var fetchAllAlbumsCount: Int { locked { _fetchAllAlbumsCount } }
    /// Awaited (when set) before returning, so a test can hold a sync pass open mid-run.
    var fetchAllAlbumsGate: (@Sendable () async -> Void)?

    func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] {
        locked { _fetchAllAlbumsCount += 1 }
        if let gate = fetchAllAlbumsGate { await gate() }
        if let fetchAllAlbumsError { throw fetchAllAlbumsError }
        return locked { Array(_albums.values) }
    }

    /// Counts come from `_liveRecords` — the records this mock believes are actually
    /// on the server — so a wiped account reports an empty census and
    /// `fetchBlobCount` stays at 0.
    func fetchFingerprintCensus() async throws -> CloudKitFingerprintCensus {
        locked { _fingerprintCensusCount += 1 }
        if fingerprintCensusDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: fingerprintCensusDelayNanos)
        }
        if let fingerprintCensusError { throw fingerprintCensusError }
        if let fingerprintCensusOverride { return fingerprintCensusOverride }
        return locked {
            var counts: [String: Int] = [:]
            for item in _liveRecords.values where !item.keyFingerprint.isEmpty {
                counts[item.keyFingerprint, default: 0] += 1
            }
            return .counted(mediaCount: _liveRecords.count, fingerprints: counts)
        }
    }

    func tombstoneAlbum(albumID: String) async throws {
        if let deleteError {
            locked { _tombstonedAlbumCalls.append(albumID) }
            throw deleteError
        }
        locked {
            _tombstonedAlbumCalls.append(albumID)
            if let existing = _albums[albumID] {
                _albums[albumID] = CloudKitAlbumMetadata(
                    albumID: existing.albumID, encName: existing.encName, createdAt: existing.createdAt,
                    isHidden: existing.isHidden, deletedAt: Date(), schemaVersion: existing.schemaVersion,
                    keyFingerprint: existing.keyFingerprint,
                    recordChangeTag: existing.recordChangeTag)
            }
            // `.deleteSelf` cascades the album tombstone to its media server-side,
            // so those records stop being live here too.
            _liveRecords = _liveRecords.filter { $0.value.albumID != albumID }
        }
    }

    var fetchChangesErrorOnce: Error?
    var fetchChangesDelayNanos: UInt64 = 0
    func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        locked { _fetchChangesCount += 1 }
        if fetchChangesDelayNanos > 0 { try? await Task.sleep(nanoseconds: fetchChangesDelayNanos) }
        if let error = fetchChangesErrorOnce { fetchChangesErrorOnce = nil; throw error }
        if let fetchChangesError { throw fetchChangesError }
        return changeSet
    }

    private(set) var committedTokenCount = 0
    private(set) var resetChangeTokenCount = 0
    private(set) var recreateZoneCount = 0
    var hasChangeTokenValue = false
    func loadChangeToken() async -> CKServerChangeToken? { nil }
    func hasChangeToken() async -> Bool { hasChangeTokenValue }
    func commitChangeToken(_ token: CKServerChangeToken?) async {
        locked { committedTokenCount += 1 }
    }
    func resetChangeToken() async { locked { resetChangeTokenCount += 1 } }
    func recreateZone() async throws { locked { recreateZoneCount += 1 } }

    private(set) var ensureZoneCalls = 0
    func ensureZoneExists() async throws {
        locked { ensureZoneCalls += 1 }
    }

    var registerSubscriptionError: Error?
    func registerZoneSubscription() async throws {
        guard accountAvailableValue else { return }
        if let registerSubscriptionError { throw registerSubscriptionError }
        locked { _registerSubscriptionCount += 1 }
    }

    func cancelAll() {}

    /// Awaited (when set) before returning, so a test can inject work — e.g. a
    /// user cancel — into the pre-run preflight window between planning and the
    /// item loop.
    var accountAvailableGate: (@Sendable () async -> Void)?

    func accountAvailable() async -> Bool {
        if let gate = accountAvailableGate { await gate() }
        return accountAvailableValue
    }
}
