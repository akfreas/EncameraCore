//
//  CloudKitUploadQueue.swift
//  EncameraCore
//
//  Durable holding area for media that has been captured but not yet uploaded to
//  CloudKit.
//
//  Why this exists: encrypted media for a CloudKit album normally lives under
//  `Library/Caches` (`CloudKitStorageModel.rootURL` -> `CloudKitBlobCache`),
//  which iOS is free to delete when the device runs low on space and which is
//  excluded from backup. That is correct as long as a file only lands there
//  AFTER CloudKit has its own copy — CloudKit is the real storage and the local
//  file is a convenience.
//
//  The moment the app shows a photo as saved before CloudKit has it, that stops
//  being true: the only copy would sit in a directory the OS may reclaim. So a
//  capture is written HERE first — under Application Support, which is durable
//  and included in the device backup — and only moves into the evictable cache
//  once the upload is confirmed. Nothing deletes a file from here that CloudKit
//  has not acknowledged.
//

import Foundation

/// One capture waiting to reach CloudKit.
public struct CloudKitPendingUpload: Codable, Sendable, Equatable {

    public let albumID: String
    public let mediaID: String
    public let mediaTypeRawValue: Int
    /// Unique per component — a Live Photo's photo and video halves share a
    /// `mediaID` but are separate records.
    public let recordName: String
    public let createdAt: Date
    public let sizeBytes: Int64
    /// Filename inside this album's holding folder. Deliberately relative: the
    /// app container path changes between installs, so a stored absolute URL
    /// stops resolving after a restore (the same reason `CloudKitBlobCache`
    /// stores `relativePath`).
    public let fileName: String
    /// Fingerprint of the key this record was encrypted under, carried across a
    /// relaunch so a retried upload still names the key its blob was proven against.
    /// Required: a queued upload that cannot say which key wrote its bytes has nothing
    /// to publish. A manifest from a build before this was required does not decode, and
    /// is discarded rather than migrated — no shipped build ever wrote one.
    public let keyFingerprint: String

    public var queuedAt: Date
    public var attempts: Int
    /// Description of the most recent failure, for the UI and for diagnosis.
    public var lastError: String?
    /// Set when retrying is pointless (storage full, no account). The file is
    /// still kept — the user's photo is not thrown away because iCloud is full.
    public var hasGivenUp: Bool

    public var mediaType: MediaType {
        MediaType(rawValue: mediaTypeRawValue) ?? .unknown
    }
}

public actor CloudKitUploadQueue: DebugPrintable {

    /// One instance per process: the manifest has a single on-disk copy, and two
    /// in-memory owners writing it from divergent snapshots would clobber each
    /// other — the same reasoning as `CloudKitBlobCache.shared`.
    public static let shared = CloudKitUploadQueue()

    private let baseDir: URL
    /// Keyed by record name, which is unique per component.
    private var pending: [String: CloudKitPendingUpload] = [:]
    private var loaded = false
    /// Set when the manifest existed but could not be (fully) decoded. While
    /// true, `sweep()` refuses to delete "orphan" files: with the manifest gone
    /// every pending capture would look unclaimed, and deleting them would
    /// destroy the only copy of the user's photos.
    private var manifestUnreadable = false

    private var manifestURL: URL { baseDir.appendingPathComponent("queue.json") }

    /// `~/Library/Application Support/CloudKitUploads/`.
    ///
    /// Application Support rather than Caches because these files are the only
    /// copy of the user's media until the upload lands. For the same reason they
    /// are deliberately NOT excluded from backup — unlike the migration
    /// checkpoints in `CloudKitMigrationPlan`, which describe work that can be
    /// redone, a pending capture cannot be reconstructed from anywhere else.
    public static var defaultBaseDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudKitUploads", isDirectory: true)
    }

    public init(baseDir: URL = CloudKitUploadQueue.defaultBaseDir) {
        self.baseDir = baseDir
    }

    private func albumDir(_ albumID: String) -> URL {
        baseDir.appendingPathComponent(CloudKitBlobCache.albumFolderName(albumID), isDirectory: true)
    }

    /// Filename for a component, with the record name's `#` separator replaced.
    ///
    /// `#` is a URL fragment delimiter, so a path component containing one does
    /// not survive a `URL` round trip intact — which made `sweep` fail to match a
    /// file against the record that owned it and delete a pending capture as an
    /// orphan. Record names are `<uuid>#<type>` and UUIDs contain no underscore,
    /// so the substitution stays unique.
    static func fileName(forRecordName recordName: String, extension ext: String) -> String {
        let safe = recordName.replacingOccurrences(of: "#", with: "_")
        return ext.isEmpty ? safe : "\(safe).\(ext)"
    }

    /// Absolute location of a pending item's ciphertext, rebuilt from the
    /// relative parts every time rather than stored.
    private func fileURL(for item: CloudKitPendingUpload) -> URL {
        albumDir(item.albumID).appendingPathComponent(item.fileName)
    }

    // MARK: - Persistence

    /// Tolerates entries that fail to decode individually, so one corrupt or
    /// schema-drifted entry costs that entry's metadata, not the whole manifest.
    private struct LenientPendingUpload: Decodable {
        let value: CloudKitPendingUpload?
        init(from decoder: Decoder) {
            value = try? CloudKitPendingUpload(from: decoder)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        if let decoded = try? JSONDecoder().decode([CloudKitPendingUpload].self, from: data) {
            pending = Dictionary(decoded.map { ($0.recordName, $0) }, uniquingKeysWith: { _, newer in newer })
            printDebug("loadIfNeeded ok pending=\(pending.count)")
            return
        }
        // Strict decode failed — salvage what individual entries still decode
        // (a future schema change to one field must not orphan every capture).
        if let lenient = try? JSONDecoder().decode([LenientPendingUpload].self, from: data) {
            let items = lenient.compactMap(\.value)
            pending = Dictionary(items.map { ($0.recordName, $0) }, uniquingKeysWith: { _, newer in newer })
            manifestUnreadable = items.count != lenient.count
            printDebug("loadIfNeeded SALVAGED pending=\(pending.count) dropped=\(lenient.count - items.count) — orphan deletion disabled this launch")
            return
        }
        // Nothing decodes. The files the manifest described are still on disk;
        // `manifestUnreadable` stops `sweep()` from deleting them as orphans.
        manifestUnreadable = true
        printDebug("loadIfNeeded FAILED manifest unreadable file=\(manifestURL.lastPathComponent) — starting empty; files are left in place and sweep will not delete orphans")
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(pending.values))
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            // The files are already on disk; a failed manifest write costs us the
            // record of them, which `sweep()` reports rather than hides.
            printDebug("persist FAILED pending=\(pending.count) raw=\(error)")
        }
    }

    // MARK: - Enqueue

    /// Takes ownership of `upload`'s ciphertext by moving it into the holding
    /// folder, and records it as waiting. Returns the upload rewritten to point
    /// at its new home, so the caller uploads from the durable copy.
    @discardableResult
    public func enqueue(_ upload: CloudKitMediaUpload) throws -> CloudKitMediaUpload {
        loadIfNeeded()
        let dir = albumDir(upload.albumID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileName = Self.fileName(forRecordName: upload.recordName,
                                     extension: upload.encryptedFileURL.pathExtension)
        let destination = dir.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: upload.encryptedFileURL, to: destination)

        let item = CloudKitPendingUpload(
            albumID: upload.albumID,
            mediaID: upload.mediaID,
            mediaTypeRawValue: upload.mediaType.rawValue,
            recordName: upload.recordName,
            createdAt: upload.createdAt,
            sizeBytes: upload.sizeBytes,
            fileName: fileName,
            keyFingerprint: upload.keyFingerprint,
            queuedAt: Date(),
            attempts: 0,
            lastError: nil,
            hasGivenUp: false
        )
        pending[item.recordName] = item
        persist()
        printDebug("enqueue ok recordName=\(item.recordName) albumID=\(item.albumID) sizeBytes=\(item.sizeBytes) pending=\(pending.count)")
        return rebuild(item, thumbURL: upload.encryptedThumbURL)
    }

    /// Rebuilds the upload description for an item still waiting, pointing at the
    /// durable copy. The thumbnail is not held here — previews live in the
    /// storage-agnostic Documents thumbnail directory, which is already durable —
    /// so the caller supplies its current location.
    public func rebuild(_ item: CloudKitPendingUpload, thumbURL: URL?) -> CloudKitMediaUpload {
        CloudKitMediaUpload(
            albumID: item.albumID,
            mediaID: item.mediaID,
            mediaType: item.mediaType,
            createdAt: item.createdAt,
            sizeBytes: item.sizeBytes,
            encryptedFileURL: fileURL(for: item),
            encryptedThumbURL: thumbURL,
            recordName: item.recordName,
            keyFingerprint: item.keyFingerprint
        )
    }

    // MARK: - Reads

    /// The durable copy for a record still waiting to upload, if there is one and
    /// it is still on disk. This is what lets a just-captured photo open before
    /// CloudKit has ever seen it.
    public func pendingFileURL(recordName: String) -> URL? {
        loadIfNeeded()
        guard let item = pending[recordName] else { return nil }
        let url = fileURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            printDebug("pendingFileURL MISS recordName=\(recordName) reason=fileMissingOnDisk file=\(item.fileName)")
            return nil
        }
        return url
    }

    /// Oldest first, skipping anything that has given up. Oldest-first matters:
    /// a backlog should drain in capture order so the user's earliest photo is
    /// the first one backed up.
    public func next() -> CloudKitPendingUpload? {
        loadIfNeeded()
        return pending.values
            .filter { !$0.hasGivenUp }
            .min { $0.queuedAt < $1.queuedAt }
    }

    public func all() -> [CloudKitPendingUpload] {
        loadIfNeeded()
        return pending.values.sorted { $0.queuedAt < $1.queuedAt }
    }

    /// Items still waiting, i.e. excluding the ones that have given up.
    public func waitingCount() -> Int {
        loadIfNeeded()
        return pending.values.filter { !$0.hasGivenUp }.count
    }

    public func givenUp() -> [CloudKitPendingUpload] {
        loadIfNeeded()
        return pending.values.filter(\.hasGivenUp).sorted { $0.queuedAt < $1.queuedAt }
    }

    /// Whether a specific media item (either component) is still waiting or has
    /// failed — what the gallery badge reads.
    public func state(forMediaID mediaID: String) -> CloudKitUploadState {
        loadIfNeeded()
        let components = pending.values.filter { $0.mediaID == mediaID }
        if components.isEmpty { return .uploaded }
        if components.contains(where: \.hasGivenUp) { return .failed }
        return .waiting
    }

    // MARK: - Outcomes

    /// Records a failed attempt that is worth retrying.
    public func recordAttempt(recordName: String, error: Error) {
        loadIfNeeded()
        guard var item = pending[recordName] else { return }
        item.attempts += 1
        item.lastError = String(describing: error)
        pending[recordName] = item
        persist()
        printDebug("recordAttempt recordName=\(recordName) attempts=\(item.attempts) raw=\(error)")
    }

    /// Stops retrying an item, keeping its file. Used for failures where trying
    /// again cannot help — storage full, no iCloud account.
    public func giveUp(recordName: String, reason: Error) {
        loadIfNeeded()
        guard var item = pending[recordName] else { return }
        item.attempts += 1
        item.lastError = String(describing: reason)
        item.hasGivenUp = true
        pending[recordName] = item
        persist()
        printDebug("giveUp recordName=\(recordName) attempts=\(item.attempts) — file KEPT raw=\(reason)")
    }

    /// Clears an item whose bytes are confirmed to be in CloudKit, deleting the
    /// durable copy. Call this only after the cache copy is in place: the order
    /// is copy-to-cache, verify, then this — so a crash mid-handover leaves a
    /// duplicate rather than nothing.
    public func complete(recordName: String) {
        loadIfNeeded()
        guard let item = pending[recordName] else { return }
        let url = fileURL(for: item)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            // The upload succeeded, so the record must still go; a leftover file
            // is picked up by the next `sweep()`.
            printDebug("complete WARNING recordName=\(recordName) file remove failed file=\(item.fileName) raw=\(error)")
        }
        pending[recordName] = nil
        persist()
        printDebug("complete ok recordName=\(recordName) pending=\(pending.count)")
    }

    /// Drops an item the user deleted before it ever uploaded, removing its
    /// durable copy. Distinct from `complete` in intent — nothing reached
    /// CloudKit — and the caller needs to know whether the item was pending,
    /// because a never-uploaded record has nothing to delete remotely.
    @discardableResult
    public func cancel(recordName: String) -> Bool {
        loadIfNeeded()
        guard let item = pending[recordName] else { return false }
        let url = fileURL(for: item)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            printDebug("cancel WARNING recordName=\(recordName) file remove failed file=\(item.fileName) raw=\(error)")
        }
        pending[recordName] = nil
        persist()
        printDebug("cancel ok recordName=\(recordName) pending=\(pending.count)")
        return true
    }

    /// Retries an item that had given up — for when the underlying reason may
    /// have changed (the user freed up iCloud storage, or signed back in).
    public func retryGivenUp() {
        loadIfNeeded()
        var revived = 0
        for (name, var item) in pending where item.hasGivenUp {
            item.hasGivenUp = false
            item.attempts = 0
            pending[name] = item
            revived += 1
        }
        guard revived > 0 else { return }
        persist()
        printDebug("retryGivenUp ok revived=\(revived)")
    }

    // MARK: - Housekeeping

    /// Reconciles the manifest against what is actually on disk: drops records
    /// whose file has vanished, and deletes files no record claims. Without this
    /// a bug in the uploader would quietly accumulate orphaned media in
    /// Application Support forever.
    public func sweep() {
        loadIfNeeded()
        var droppedRecords = 0
        for (name, item) in pending where !FileManager.default.fileExists(atPath: fileURL(for: item).path) {
            printDebug("sweep dropping recordName=\(name) reason=fileMissingOnDisk file=\(item.fileName)")
            pending[name] = nil
            droppedRecords += 1
        }

        // With an unreadable manifest, every file on disk looks unclaimed — and
        // each one may be the only copy of a photo. Refuse to treat them as
        // orphans; they upload again once a readable manifest re-claims them or
        // stay put for diagnosis.
        if manifestUnreadable {
            printDebug("sweep skip orphanDeletion reason=manifestUnreadable — unclaimed files kept")
            if droppedRecords > 0 { persist() }
            return
        }

        var quarantinedOrphans = 0
        // Matched on (album folder, filename) rather than whole path strings.
        // Comparing `URL.path` values is what broke here before: the two sides
        // are built differently and a mismatch means condemning a file a record
        // still owns — i.e. a photo that has not been uploaded yet.
        //
        // Orphans are MOVED to a quarantine folder rather than deleted, and only
        // removed for good after `quarantineGracePeriod`. This is the queue's one
        // destructive operation on user media; a bug in the matching (it has
        // happened) or a manifest that goes unreadable and is later overwritten
        // by a fresh one now costs a detour through quarantine, not the photo.
        var known: Set<String> = []
        for item in pending.values {
            known.insert("\(CloudKitBlobCache.albumFolderName(item.albumID))/\(item.fileName)")
        }
        let albumDirs = (try? FileManager.default.contentsOfDirectory(at: baseDir,
                                                                     includingPropertiesForKeys: nil)) ?? []
        for dir in albumDirs where dir.hasDirectoryPath && dir.lastPathComponent != Self.quarantineFolderName {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where !known.contains("\(dir.lastPathComponent)/\(file.lastPathComponent)") {
                do {
                    try FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
                    let destination = quarantineDir.appendingPathComponent("\(dir.lastPathComponent)-\(file.lastPathComponent)")
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: file, to: destination)
                    quarantinedOrphans += 1
                } catch {
                    printDebug("sweep WARNING orphan quarantine failed file=\(file.lastPathComponent) raw=\(error)")
                }
            }
        }

        let expired = pruneQuarantine()

        if droppedRecords > 0 || quarantinedOrphans > 0 || expired > 0 {
            persist()
            printDebug("sweep ok droppedRecords=\(droppedRecords) quarantinedOrphans=\(quarantinedOrphans) quarantineExpired=\(expired) pending=\(pending.count)")
        }
    }

    static let quarantineFolderName = "quarantine"
    private var quarantineDir: URL { baseDir.appendingPathComponent(Self.quarantineFolderName, isDirectory: true) }
    /// How long a quarantined file survives before it is really deleted.
    static let quarantineGracePeriod: TimeInterval = 30 * 24 * 60 * 60

    /// Deletes quarantined files older than the grace period. Returns how many.
    private func pruneQuarantine() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: quarantineDir,
                                                                  includingPropertiesForKeys: [.creationDateKey])) ?? []
        var expired = 0
        let cutoff = Date().addingTimeInterval(-Self.quarantineGracePeriod)
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            guard created < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                expired += 1
            } catch {
                printDebug("sweep WARNING quarantine prune failed file=\(file.lastPathComponent) raw=\(error)")
            }
        }
        return expired
    }

    /// Drops everything, files included. For the erase flows, which must not
    /// leave user media behind.
    public func clearAll() throws {
        loadIfNeeded()
        if FileManager.default.fileExists(atPath: baseDir.path) {
            try FileManager.default.removeItem(at: baseDir)
        }
        pending.removeAll()
        printDebug("clearAll ok")
    }
}

/// Where a media item stands with respect to CloudKit, for the gallery badge.
public enum CloudKitUploadState: Sendable, Equatable {
    /// CloudKit has it (or it never needed uploading — e.g. a local album).
    case uploaded
    /// Written to this device, waiting its turn to upload.
    case waiting
    /// Written to this device; uploading failed in a way retrying cannot fix.
    case failed
}
