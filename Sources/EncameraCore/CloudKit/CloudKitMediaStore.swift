//
//  CloudKitMediaStore.swift
//  EncameraCore
//
//  The concrete Option-A record store: one `EncMedia` record per media item
//  carrying the index fields plus the eager thumbnail and lazy blob assets.
//  All CloudKit I/O goes through an injected `CloudKitDatabaseAdapter`, and the
//  account gate / change token live in app-group defaults.
//  See plans/cloudkit-migration/02-cloudkit-media-store.md.
//

import Foundation
import CloudKit

public final class CloudKitMediaStore: CloudKitMediaStoring, DebugPrintable {

    private let container: CloudKitContainer
    private let adapter: CloudKitDatabaseAdapter
    private let defaults: UserDefaults
    private let zoneID: CKRecordZone.ID

    /// Per-namespace change-token key. The zone is shared across albums, but each
    /// album keeps its own independent cursor into the zone — otherwise syncing one
    /// album would advance the token for all the others and they'd miss changes.
    private let tokenKey: String
    /// Written only by builds that issued uploads as long-lived operations; read now
    /// solely so it can be deleted. See `purgeLegacyLongLivedState()`.
    private let longLivedMapKey = "cloudkit_longlived_ops_v1"
    /// Keyed by container id for the same reason as `CloudKitContainer`'s
    /// zone-created flag: the subscription lives in a specific container, so a
    /// flag set for one container must not suppress registration in another.
    private let subscriptionCreatedKey = "cloudkit_zone_subscription_v1_" + CloudKitSchema.containerID
    private let zoneSubscriptionID = "EncameraZoneSubscription"

    /// Index (non-asset) fields, used as `desiredKeys` for the cheap metadata sync.
    /// Internal rather than private so a test can assert every list names the
    /// fingerprint: a fetch that omits it returns records the mapper cannot build, and
    /// the media vanishes from the album rather than failing visibly.
    static let metadataKeys: [CKRecord.FieldKey] = [
        CloudKitSchema.EncMedia.albumID,
        CloudKitSchema.EncMedia.mediaID,
        CloudKitSchema.EncMedia.mediaType,
        CloudKitSchema.EncMedia.createdAt,
        CloudKitSchema.EncMedia.sizeBytes,
        CloudKitSchema.EncMedia.creationDevice,
        CloudKitSchema.EncMedia.schemaVersion,
        CloudKitSchema.EncMedia.keyFingerprint
    ]

    /// `desiredKeys` for the zone change feed, which carries BOTH record types.
    /// The parameter is zone-wide, not per-type, so the album fields have to be
    /// named here or an `EncAlbum` record arrives with none of them set and is
    /// discarded as unmappable. All small scalars — never add `encBlob`, which is
    /// the whole point of the lazy-blob guarantee.
    static let changeFeedKeys: [CKRecord.FieldKey] = metadataKeys + [
        CloudKitSchema.EncAlbum.encName,
        CloudKitSchema.EncAlbum.isHidden,
        CloudKitSchema.EncAlbum.keyFingerprint
    ]

    public init(container: CloudKitContainer = .shared,
                adapter: CloudKitDatabaseAdapter? = nil,
                defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard,
                tokenNamespace: String = "") {
        self.container = container
        self.defaults = defaults
        self.zoneID = container.zoneID
        self.tokenKey = tokenNamespace.isEmpty
            ? "cloudkit_zone_change_token_v1"
            : "cloudkit_zone_change_token_v1_\(tokenNamespace)"
        self.adapter = adapter ?? CKDatabaseAdapter(database: container.privateDB)
        purgeLegacyLongLivedState()
    }

    // MARK: - Account

    public func accountAvailable() async -> Bool {
        await container.isCloudKitAvailable()
    }

    // MARK: - Upload

    public func upload(_ item: CloudKitMediaUpload,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        guard await accountAvailable() else { throw CloudKitMediaStoreError.accountUnavailable }

        // Upload the preview from a private snapshot, never the live file.
        //
        // CloudKit fingerprints an asset when the operation is submitted and
        // reads it again while uploading; if the bytes change in between it
        // rejects the record with "Asset File Modified" (17/3003). The preview
        // file is shared — a Live Photo's photo and video components are keyed by
        // the same media id, so both records point at ONE `<id>.preview` — and it
        // is rewritten whenever a preview is regenerated or re-fetched. That is
        // exactly how a Live Photo lost its video half: the preview was deleted
        // and re-downloaded while the second component was uploading it.
        // Copying first makes the upload immune to whatever else touches it.
        let snapshot = item.encryptedThumbURL.flatMap { Self.snapshotForUpload($0) }
        defer {
            if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
        }

        let record = makeRecord(for: item, thumbnailURL: snapshot ?? item.encryptedThumbURL)
        let recordName = item.recordName
        printDebug("upload start recordName=\(recordName) albumID=\(item.albumID) mediaType=\(item.mediaType) sizeBytes=\(item.sizeBytes) zone=\(zoneID.zoneName) hasThumb=\(item.encryptedThumbURL != nil)")
        do {
            // An ordinary (non-long-lived) save: an upload interrupted by app
            // termination is re-driven from the durable `MigrationPlan` checkpoint,
            // which re-verifies the item with a cheap fetch-by-id before re-uploading.
            // Nothing about this call survives the process, and nothing has to be
            // re-attached on the next launch — see ENC-133.
            let saved = try await adapter.save(
                records: [record],
                savePolicy: .ifServerRecordUnchanged,
                perRecordProgress: { _, fraction in progress(fraction) }
            )
            // `saved` empty means the operation reported success without returning the
            // record — falling back to the local copy would report a recordName that
            // was never confirmed by the server, so say so loudly.
            if saved.isEmpty {
                printDebug("upload WARNING recordName=\(recordName) save returned no records; reporting the unconfirmed local record")
            }
            let result = saved.first ?? record
            printDebug("upload ok recordName=\(result.recordID.recordName) changeTag=\(result.recordChangeTag ?? "nil") confirmedByServer=\(!saved.isEmpty)")
            return CloudKitMediaRef(recordName: result.recordID.recordName,
                                    recordChangeTag: result.recordChangeTag)
        } catch {
            let mapped = mapAndRecord(error)
            printDebug("upload FAILED recordName=\(recordName) mapped=\(mapped) raw=\(error)")
            throw mapped
        }
    }

    /// Copies `source` somewhere only this upload knows about. Returns nil if the
    /// copy fails, in which case the caller falls back to the live file — an
    /// upload that might hit the modified-asset race is still better than
    /// silently dropping the thumbnail.
    private static func snapshotForUpload(_ source: URL) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckupload-\(UUID().uuidString)-\(source.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            printDebug("snapshotForUpload FAILED source=\(source.lastPathComponent) raw=\(error) — uploading the live file instead")
            return nil
        }
    }

    private func makeRecord(for item: CloudKitMediaUpload, thumbnailURL: URL?) -> CKRecord {
        let recordID = CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitSchema.EncMedia.recordType, recordID: recordID)
        apply(item, thumbnailURL: thumbnailURL, to: record)
        return record
    }

    /// Writes this upload's fields onto a brand-new record.
    private func apply(_ item: CloudKitMediaUpload, thumbnailURL: URL?, to record: CKRecord) {
        record[CloudKitSchema.EncMedia.albumID] = item.albumID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaID] = item.mediaID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaType] = Int64(item.mediaType.rawValue) as CKRecordValue
        record[CloudKitSchema.EncMedia.createdAt] = item.createdAt as CKRecordValue
        record[CloudKitSchema.EncMedia.sizeBytes] = item.sizeBytes as CKRecordValue
        record[CloudKitSchema.EncMedia.creationDevice] = DeviceIdentity.currentID(defaults: defaults) as CKRecordValue
        record[CloudKitSchema.EncMedia.schemaVersion] = item.schemaVersion as CKRecordValue
        record[CloudKitSchema.EncMedia.keyFingerprint] = item.keyFingerprint as CKRecordValue
        if let thumbnailURL {
            record[CloudKitSchema.EncMedia.encThumbnail] = CKAsset(fileURL: thumbnailURL)
        }
        record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: item.encryptedFileURL)
        // Relational link to the owning EncAlbum (record name == albumID hash). The
        // `.deleteSelf` action cascades a media delete when the album is deleted; the
        // same reference is set as `parent` for future record sharing. We do NOT need
        // the album record to exist first — CloudKit stores the reference regardless.
        let albumRecordID = CKRecord.ID(recordName: item.albumID, zoneID: zoneID)
        record[CloudKitSchema.EncMedia.albumRef] = CKRecord.Reference(recordID: albumRecordID, action: .deleteSelf)
        record.parent = CKRecord.Reference(recordID: albumRecordID, action: .none)
    }

    // MARK: - Albums (chunk 13)

    public func saveAlbum(_ album: CloudKitAlbumUpload) async throws {
        guard await accountAvailable() else { throw CloudKitMediaStoreError.accountUnavailable }
        let recordID = CKRecord.ID(recordName: album.albumID, zoneID: zoneID)
        do {
            // Fetch-then-update so a re-save carries the server's change tag and is
            // an update rather than a rejected insert; build fresh when the record
            // is absent.
            let existing = try await adapter.fetch(recordIDs: [recordID],
                                                   desiredKeys: nil,
                                                   perRecordProgress: { _, _ in })
            let record = existing[recordID] ?? CKRecord(recordType: CloudKitSchema.EncAlbum.recordType, recordID: recordID)
            record[CloudKitSchema.EncAlbum.encName] = album.encName as CKRecordValue
            record[CloudKitSchema.EncAlbum.createdAt] = album.createdAt as CKRecordValue
            record[CloudKitSchema.EncAlbum.isHidden] = Int64(album.isHidden ? 1 : 0) as CKRecordValue
            record[CloudKitSchema.EncAlbum.schemaVersion] = album.schemaVersion as CKRecordValue
            record[CloudKitSchema.EncAlbum.keyFingerprint] = album.keyFingerprint as CKRecordValue
            _ = try await adapter.save(records: [record],
                                       savePolicy: .ifServerRecordUnchanged,
                                       perRecordProgress: { _, _ in })
        } catch {
            throw mapAndRecord(error)
        }
    }

    public func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] {
        do {
            let records = try await adapter.query(recordType: CloudKitSchema.EncAlbum.recordType,
                                                  predicate: NSPredicate(value: true),
                                                  zoneID: zoneID,
                                                  desiredKeys: nil)
            return records.compactMap(albumMetadata(from:))
        } catch {
            let mapped = mapAndRecord(error)
            if case .zoneNotFound = mapped {
                printDebug("fetchAllAlbums zoneNotFound zone=\(zoneID.zoneName) container=\(CloudKitSchema.containerID) — reporting no albums; a zone that does not exist holds none")
                return []
            }
            throw mapped
        }
    }

    /// See `CloudKitMediaStoring.fetchFingerprintCensus()`. Asset-free by
    /// construction: `desiredKeys` names only the fingerprint, so neither `encBlob`
    /// nor `encThumbnail` is ever transferred.
    ///
    /// The predicate filters on `createdAt` (matching every record — uploads always
    /// set it) instead of `NSPredicate(value: true)` deliberately: a `true` predicate
    /// resolves through the system `recordName` index, which the deploy runbook never
    /// prescribes for `EncMedia`, whereas `createdAt` is Queryable in every deployed
    /// container. `keyFingerprint` itself needs no index — it is only retrieved via
    /// `desiredKeys`, never filtered on.
    public func fetchFingerprintCensus() async throws -> CloudKitFingerprintCensus {
        let desiredKeys = [CloudKitSchema.EncMedia.keyFingerprint]
        do {
            let records = try await adapter.query(recordType: CloudKitSchema.EncMedia.recordType,
                                                  predicate: NSPredicate(format: "%K > %@",
                                                                         CloudKitSchema.EncMedia.createdAt,
                                                                         Date.distantPast as NSDate),
                                                  zoneID: zoneID,
                                                  desiredKeys: desiredKeys)
            var counts: [String: Int] = [:]
            for record in records {
                guard let fingerprint = record[CloudKitSchema.EncMedia.keyFingerprint] as? String,
                      !fingerprint.isEmpty else { continue }   // pre-field record: unknown, not counted
                counts[fingerprint, default: 0] += 1
            }
            printDebug("fetchFingerprintCensus ok records=\(records.count) fingerprints=\(counts.count)")
            return .counted(mediaCount: records.count, fingerprints: counts)
        } catch {
            let mapped = mapAndRecord(error)
            // A container whose schema predates the `createdAt` index — or the
            // `EncMedia` record type itself — cannot answer the query. Both degrade
            // to "unresolved" rather than an error.
            if Self.isSchemaNotReady(error) {
                printDebug("fetchFingerprintCensus degraded — schema cannot answer the census query yet; index unavailable (raw=\(error))")
                return .indexUnavailable
            }
            throw mapped
        }
    }

    /// True when the failure means "the server schema does not know this field/type
    /// yet" rather than a real I/O failure. CloudKit reports an unindexed field as
    /// `.invalidArguments` and an unknown record type as `.unknownItem`.
    private static func isSchemaNotReady(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .invalidArguments || ckError.code == .unknownItem
    }

    public func deleteAlbum(albumID: String) async throws {
        if CloudKitStoreTestHooks.failDeletes { throw CloudKitMediaStoreError.retry(after: 1) }
        let recordID = CKRecord.ID(recordName: albumID, zoneID: zoneID)
        do {
            // Every `EncMedia` parents to this record with `.deleteSelf`, so one op
            // removes the album, its media, and their blobs. Soft-deleting instead
            // never cascaded — `.deleteSelf` fires on a real delete only — which is
            // why deleted albums used to keep billing the user's quota forever, and
            // why re-creating an album with the same name resurrected its photos.
            _ = try await adapter.delete(recordIDs: [recordID])
        } catch {
            throw mapAndRecord(error)
        }
    }

    private func albumMetadata(from record: CKRecord) -> CloudKitAlbumMetadata? {
        guard let encName = record[CloudKitSchema.EncAlbum.encName] as? String,
              let createdAt = record[CloudKitSchema.EncAlbum.createdAt] as? Date else {
            return nil
        }
        let isHidden = ((record[CloudKitSchema.EncAlbum.isHidden] as? Int64) ?? 0) != 0
        let schemaVersion = (record[CloudKitSchema.EncAlbum.schemaVersion] as? Int64) ?? CloudKitSchema.currentSchemaVersion
        // Absent stays nil ("unknown"), matching the write side's "only when known" rule.
        let keyFingerprint = record[CloudKitSchema.EncAlbum.keyFingerprint] as? String
        return CloudKitAlbumMetadata(albumID: record.recordID.recordName,
                                     encName: encName,
                                     createdAt: createdAt,
                                     isHidden: isHidden,
                                     schemaVersion: schemaVersion,
                                     keyFingerprint: keyFingerprint,
                                     recordChangeTag: record.recordChangeTag)
    }

    // MARK: - Metadata sync (asset-free, optional eager thumbnail)

    public func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata] {
        var desiredKeys = Self.metadataKeys
        if includeThumbnail { desiredKeys.append(CloudKitSchema.EncMedia.encThumbnail) }
        // Note: never request `encBlob` here — that is the lazy-fetch guarantee.

        let predicate = NSPredicate(format: "%K == %@", CloudKitSchema.EncMedia.albumID, albumID)
        do {
            // Asking for the thumbnail turns this from an index query into an asset
            // transfer, so it gets the same top QoS band as `fetchAsset`. Without the
            // thumbnail there is nothing bulky to move and the default is right.
            let records = try await adapter.query(recordType: CloudKitSchema.EncMedia.recordType,
                                                  predicate: predicate,
                                                  zoneID: zoneID,
                                                  desiredKeys: desiredKeys,
                                                  qualityOfService: includeThumbnail ? .userInteractive : .userInitiated)
            return records.compactMap(metadata(from:))
        } catch {
            throw mapAndRecord(error)
        }
    }

    public func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata? {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            // Fetch-by-record-ID is strongly consistent: a record saved moments ago is
            // visible here, unlike the query in `fetchMetadata`. A missing record is
            // simply absent from the result (the per-record API does not fail the op).
            let fetched = try await adapter.fetch(recordIDs: [recordID],
                                                  desiredKeys: Self.metadataKeys,
                                                  perRecordProgress: { _, _ in })
            // Each miss below is a distinct cause with a very different fix, and all
            // three used to collapse into a bare `nil` at the call site.
            guard let record = fetched[recordID] else {
                printDebug("fetchRecordMetadata MISS recordName=\(recordName) zone=\(zoneID.zoneName) — no record returned by fetch-by-id")
                return nil
            }
            guard let meta = metadata(from: record) else {
                printDebug("fetchRecordMetadata MISS recordName=\(recordName) — record exists but required fields are absent (albumID/mediaID/createdAt); keys present: \(record.allKeys())")
                return nil
            }
            printDebug("fetchRecordMetadata hit recordName=\(recordName) sizeBytes=\(meta.sizeBytes) changeTag=\(meta.recordChangeTag ?? "nil")")
            return meta
        } catch {
            let mapped = mapAndRecord(error)
            printDebug("fetchRecordMetadata FAILED recordName=\(recordName) mapped=\(mapped) raw=\(error)")
            throw mapped
        }
    }

    // MARK: - Lazy asset fetches

    public func fetchBlob(recordName: String,
                          to destination: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        try await fetchAsset(recordName: recordName,
                             assetKey: CloudKitSchema.EncMedia.encBlob,
                             to: destination,
                             progress: progress)
    }

    public func fetchThumbnail(recordName: String, to destination: URL) async throws {
        try await fetchAsset(recordName: recordName,
                             assetKey: CloudKitSchema.EncMedia.encThumbnail,
                             to: destination,
                             progress: { _ in })
    }

    private func fetchAsset(recordName: String,
                            assetKey: CKRecord.FieldKey,
                            to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            // `.userInteractive` rather than the default `.userInitiated`: a blob or
            // thumbnail is always fetched because something on screen is waiting for
            // it, and CloudKit transfers assets markedly faster at the top QoS band —
            // reports of 5-10x on the same 100-200KB asset are common. Paired with the
            // single-key `desiredKeys` below, which keeps the transfer to just this
            // asset (a blob fetch never drags the thumbnail along, or vice versa).
            let records = try await adapter.fetch(recordIDs: [recordID],
                                                  desiredKeys: [assetKey],
                                                  qualityOfService: .userInteractive,
                                                  perRecordProgress: { _, fraction in progress(fraction) })
            guard let record = records[recordID],
                  let asset = record[assetKey] as? CKAsset,
                  let sourceURL = asset.fileURL else {
                throw CloudKitMediaStoreError.notFound
            }
            // CloudKit owns the temp URL and may delete it — copy out before returning.
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch let error as CloudKitMediaStoreError {
            throw error
        } catch {
            throw mapAndRecord(error)
        }
    }

    // MARK: - Delete

    public func delete(recordName: String) async throws {
        if CloudKitStoreTestHooks.failDeletes { throw CloudKitMediaStoreError.retry(after: 1) }
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            // Single op removes the record and, with it, both assets — atomically.
            _ = try await adapter.delete(recordIDs: [recordID])
        } catch {
            throw mapAndRecord(error)
        }
    }

    // MARK: - Delta sync

    public func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        do {
            // Pure: fetch from exactly `token`; the caller commits the new token only
            // after the changes are durably applied.
            let result = try await adapter.fetchZoneChanges(zoneID: zoneID,
                                                            since: token,
                                                            desiredKeys: Self.changeFeedKeys)
            // Split by record type. `metadata(from:)` requires `EncMedia` fields and
            // returns nil for anything else, so mapping everything through it used to
            // drop every `EncAlbum` record on the floor — the albums were always
            // coming down this feed, just discarded on arrival.
            var changed: [CloudKitMediaMetadata] = []
            var changedAlbums: [CloudKitAlbumMetadata] = []
            for record in result.changed {
                switch record.recordType {
                case CloudKitSchema.EncMedia.recordType:
                    if let meta = metadata(from: record) { changed.append(meta) }
                case CloudKitSchema.EncAlbum.recordType:
                    if let meta = albumMetadata(from: record) { changedAlbums.append(meta) }
                default:
                    printDebug("fetchChanges skip recordName=\(record.recordID.recordName) unknownType=\(record.recordType)")
                }
            }

            var deleted: [String] = []
            var deletedAlbumIDs: [String] = []
            for record in result.deleted {
                switch record.recordType {
                case CloudKitSchema.EncAlbum.recordType: deletedAlbumIDs.append(record.recordName)
                default: deleted.append(record.recordName)
                }
            }

            return CloudKitChangeSet(changed: changed,
                                     deleted: deleted,
                                     changedAlbums: changedAlbums,
                                     deletedAlbumIDs: deletedAlbumIDs,
                                     token: result.token,
                                     moreComing: result.moreComing,
                                     // A cursor came back, so this answer is one the
                                     // caller may reason about absence against.
                                     snapshotComplete: result.token != nil)
        } catch {
            throw mapAndRecord(error)
        }
    }

    public func loadChangeToken() async -> CKServerChangeToken? {
        loadToken()
    }

    public func hasChangeToken() async -> Bool {
        defaults.data(forKey: tokenKey) != nil
    }

    public func commitChangeToken(_ token: CKServerChangeToken?) async {
        guard let token else { return }
        saveToken(token)
    }

    public func resetChangeToken() async {
        defaults.removeObject(forKey: tokenKey)
    }

    public func recreateZone() async throws {
        container.resetZoneCreatedFlag()
        try await container.ensureZoneExists()
    }

    // MARK: - Zone provisioning

    public func ensureZoneExists() async throws {
        try await container.ensureZoneExists()
    }

    // MARK: - Push subscription

    public func registerZoneSubscription() async throws {
        guard await accountAvailable() else { return }     // skip when no account (per research)
        if defaults.bool(forKey: subscriptionCreatedKey) { return }

        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: zoneSubscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true   // silent push
        subscription.notificationInfo = notificationInfo
        do {
            try await adapter.saveSubscription(subscription)
            defaults.set(true, forKey: subscriptionCreatedKey)
        } catch {
            throw mapAndRecord(error)
        }
    }

    // MARK: - Error mapping

    /// Maps a raw error and, when it reports the zone as gone (deleted in
    /// Settings > iCloud, account switched or wiped), invalidates the persisted
    /// zone-created and subscription flags — otherwise `ensureZoneExists()` and
    /// `registerZoneSubscription()` no-op on stale state forever and CloudKit
    /// storage stays broken until app data is cleared.
    private func mapAndRecord(_ error: Error) -> CloudKitMediaStoreError {
        let mapped = mapCKError(error)
        if case .zoneNotFound = mapped {
            container.resetZoneCreatedFlag()
            defaults.removeObject(forKey: subscriptionCreatedKey)
        }
        return mapped
    }

    // MARK: - Cancellation

    public func cancelAll() {
        adapter.cancelAll()
    }

    // MARK: - Legacy long-lived state

    /// Drops the operation-ID map older builds persisted for long-lived uploads.
    ///
    /// Those builds saved with `isLongLived: true` and re-enqueued the recorded
    /// operations on every store construction. That re-enqueue was itself the crash:
    /// `CloudKitStoreProvider.makeStore` builds a store per album namespace (album
    /// list, albums sync, per-album migration, flight check), each one fetched the
    /// same *container-wide* long-lived operation IDs, and the second
    /// `CKDatabase.add` of an operation the daemon already considers running raises
    /// an Objective-C `NSException` ("another instance of it is already running").
    /// An `NSException` is not catchable from Swift, so it killed the process during
    /// launch — every launch, until the operation aged out. See ENC-133.
    ///
    /// Uploads are no longer long-lived and nothing re-enqueues anything, so the only
    /// thing left to do is delete the stale map. Operations still outstanding in the
    /// daemon from an older build run to completion there on their own; the durable
    /// `MigrationPlan` — not CloudKit's deprecated long-lived ops — is what makes an
    /// interrupted upload resumable.
    func purgeLegacyLongLivedState() {
        guard defaults.object(forKey: longLivedMapKey) != nil else { return }
        printDebug("purgeLegacyLongLivedState clearing \(longLivedMapKey)")
        defaults.removeObject(forKey: longLivedMapKey)
    }

    // MARK: - Record <-> metadata mapping

    private func metadata(from record: CKRecord) -> CloudKitMediaMetadata? {
        guard let albumID = record[CloudKitSchema.EncMedia.albumID] as? String,
              let mediaID = record[CloudKitSchema.EncMedia.mediaID] as? String,
              let createdAt = record[CloudKitSchema.EncMedia.createdAt] as? Date else {
            return nil
        }
        let rawType = (record[CloudKitSchema.EncMedia.mediaType] as? Int64).map { Int($0) } ?? MediaType.unknown.rawValue
        let mediaType = MediaType(rawValue: rawType) ?? .unknown
        let sizeBytes = (record[CloudKitSchema.EncMedia.sizeBytes] as? Int64) ?? 0
        let creationDeviceID = (record[CloudKitSchema.EncMedia.creationDevice] as? String) ?? ""
        let schemaVersion = (record[CloudKitSchema.EncMedia.schemaVersion] as? Int64) ?? CloudKitSchema.currentSchemaVersion
        // Empty rather than nil for a record that somehow carries no fingerprint: the
        // reader treats it as "this record names no key" and falls back, instead of the
        // record failing to map at all and the media disappearing from the album.
        let keyFingerprint = (record[CloudKitSchema.EncMedia.keyFingerprint] as? String) ?? ""

        return CloudKitMediaMetadata(recordName: record.recordID.recordName,
                                     albumID: albumID,
                                     mediaID: mediaID,
                                     mediaType: mediaType,
                                     createdAt: createdAt,
                                     sizeBytes: sizeBytes,
                                     creationDeviceID: creationDeviceID,
                                     schemaVersion: schemaVersion,
                                     keyFingerprint: keyFingerprint,
                                     recordChangeTag: record.recordChangeTag)
    }

    // MARK: - Token persistence

    private func loadToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: tokenKey)
    }

}
