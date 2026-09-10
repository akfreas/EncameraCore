//
//  ChunkedBlobStore.swift
//  EncameraCore
//
//  CloudKit transport for ENC3 blobs: one small `CKAsset` per chunk. The ENC3
//  header travels on the caller's own commit record (`EncMedia.encHeader`).
//
//  Why this shape (see Documentation/chunked-ckasset-video-streaming.md):
//
//  - **A CKAsset is all-or-nothing.** CloudKit hands over no bytes until the whole
//    asset has landed — there is no range request, no resume, and
//    `perRecordProgressBlock` reports a fraction, not data. Chunking is the only
//    way to get a first frame before the last byte inside CloudKit.
//  - **Chunk records live in their own zone.** `CKFetchRecordZoneChangesOperation`
//    walks a zone's whole change feed, so putting thousands of chunk records in
//    `EncameraZone` would slow every delta sync on every device, permanently. The
//    blob zone is never delta-synced; chunks are only ever fetched by name.
//  - **Record names are computed, never queried.** `chunkRecordName` is a pure
//    function of (media record, index), so every read is a strongly-consistent
//    `CKFetchRecordsOperation` rather than an eventually-consistent
//    `CKQueryOperation`. That sidesteps the CloudKit index-latency class of bug
//    entirely — no waiting for an index to catch up, no vacuous empty result.
//  - **No `deleteSelf` references.** The documented cap is 750 source references to
//    one target, which would put a hard ceiling on chunks per video. Chunk cleanup
//    is explicit instead.
//

import Foundation
import CloudKit

// MARK: - Schema

/// Record/zone names for the chunked blob plane. Deliberately additive: it shares
/// no record type or field with `CloudKitSchema`, so a prototype cannot corrupt or
/// slow the deployed media schema.
public enum ChunkedBlobSchema {
    /// A zone of its own — see the file header. Chunk records must never enter the
    /// index zone's change feed.
    public static let zoneName = "EncameraBlobZone"

    /// The persisted "blob zone created" latch, shared by the store and the
    /// destructive erase (which must clear it after deleting the zone).
    public static var zoneCreatedDefaultsKey: String {
        "cloudkit_blob_zone_created_v1_" + CloudKitSchema.containerID
    }

    /// One record per ENC3 chunk.
    public enum Chunk {
        public static let recordType = "EncBlobChunk"
        public static let mediaRecordName = "mediaRecordName" // String
        public static let chunkIndex     = "chunkIndex"       // Int64
        public static let encChunk       = "encChunk"         // CKAsset (ciphertext)
        public static let schemaVersion  = "schemaVersion"    // Int64
    }

    public static let currentSchemaVersion: Int64 = 1

    /// Deterministic record name for a chunk. Pure function → fetch by ID.
    public static func chunkRecordName(mediaRecordName: String, index: Int) -> String {
        "\(mediaRecordName)#c\(index)"
    }
}

// MARK: - Errors

public enum ChunkedBlobError: Error, Equatable {
    case chunkNotFound(String)
    case chunkAssetMissing(String)
    case accountUnavailable
    /// A batch save reported success but returned fewer records than it was
    /// given. Failing here is what keeps a silently-dropped chunk from
    /// surfacing weeks later as a mid-playback `chunkNotFound`.
    case saveVerificationFailed(expected: Int, saved: Int)
}

// MARK: - Protocol seam

/// The seam every consumer depends on. An in-memory implementation backs unit
/// tests and the simulator; the CloudKit implementation is the real thing.
public protocol ChunkedBlobStoring: Sendable {
    /// Uploads the chunk records for an ENC3 file. The caller commits by saving its
    /// own record last (`EncMedia` with `chunkCount` set), so a partial upload reads
    /// as "not chunked yet", never as a truncated video.
    ///
    /// Idempotent and resumable: computed record names mean a retry overwrites
    /// rather than duplicates, and chunks already in the zone are detected by a
    /// metadata-only probe and skipped — a 90%-complete upload resumes with ~one
    /// probe round trip per batch plus the missing 10%.
    /// - Returns: the ENC3 header read from the file, for the caller's commit record.
    @discardableResult
    func uploadChunks(enc3FileURL: URL,
                      mediaRecordName: String,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader

    /// Fetches one chunk's ciphertext.
    func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data

    /// Fetches one chunk's ciphertext and, when the store staged it in a file of
    /// its own, hands that file over as well.
    ///
    /// The caller takes ownership of `stagedFileURL`: it must move the file
    /// somewhere it wants it or delete it, on every path. A store that never
    /// touches disk reports `nil` and the default implementation below covers it.
    func fetchChunkStaged(mediaRecordName: String, index: Int) async throws -> FetchedChunk

    /// Removes every chunk record. Records already absent are success — deleting is
    /// idempotent.
    func delete(mediaRecordName: String, chunkCount: Int) async throws
}

public extension ChunkedBlobStoring {
    func fetchChunkStaged(mediaRecordName: String, index: Int) async throws -> FetchedChunk {
        FetchedChunk(data: try await fetchChunk(mediaRecordName: mediaRecordName, index: index),
                     stagedFileURL: nil)
    }
}

/// One chunk's ciphertext, plus the file the store staged it in when it has one.
public struct FetchedChunk: Sendable {
    public let data: Data
    /// A file the receiver owns outright — nil when the bytes never went to disk.
    public let stagedFileURL: URL?

    public init(data: Data, stagedFileURL: URL?) {
        self.data = data
        self.stagedFileURL = stagedFileURL
    }
}

// MARK: - Zone latch

/// The blob zone's create-once guarantee, shared by every store that writes into
/// it.
///
/// `ChunkedBlobSchema.zoneCreatedDefaultsKey` is a single flag for the whole zone,
/// so whichever store creates it satisfies the others and the common case costs no
/// round trip at all. The destructive erase clears the flag after deleting the
/// zone, which is what makes the next write recreate it.
final class BlobZoneLatch: DebugPrintable, @unchecked Sendable {

    private let zoneID: CKRecordZone.ID
    private let zoneProvisioner: RecordZoneProvisioning
    private let zoneCreatedKey = ChunkedBlobSchema.zoneCreatedDefaultsKey
    private let defaults: UserDefaults

    init(zoneID: CKRecordZone.ID, zoneProvisioner: RecordZoneProvisioning, defaults: UserDefaults) {
        self.zoneID = zoneID
        self.zoneProvisioner = zoneProvisioner
        self.defaults = defaults
    }

    func ensureZoneExists() async throws {
        if defaults.bool(forKey: zoneCreatedKey) { return }
        do {
            try await zoneProvisioner.saveZone(CKRecordZone(zoneID: zoneID))
            defaults.set(true, forKey: zoneCreatedKey)
            printDebug("blobZone ensure ok zone=\(zoneID.zoneName)")
        } catch let error where CloudKitContainer.isBenignZoneError(error) {
            // Provably "already exists" (a benign race with another device).
            defaults.set(true, forKey: zoneCreatedKey)
            printDebug("blobZone ensure ok zone=\(zoneID.zoneName) benign=\(error)")
        }
        // Only an error that proves the zone is already there may latch the flag.
        // Every other failure propagates with the flag left clear, because the
        // latch is sticky: once set it suppresses the create for good, so setting
        // it on an unproven failure strands the install writing into a zone that
        // does not exist.
    }

    func resetZoneCreatedFlag() {
        defaults.removeObject(forKey: zoneCreatedKey)
    }

    /// Runs a write into the zone, recreating the zone and retrying once if the
    /// write proves the latch stale.
    ///
    /// The flag is per-device while the zone is per-account, so a device that has
    /// not seen another device's erase holds a flag it cannot trust. Without the
    /// retry that device skips the create, fails, and — since nothing on this path
    /// clears the flag — fails the same way on every later attempt.
    func withZone<T>(_ write: () async throws -> T) async throws -> T {
        try await ensureZoneExists()
        do {
            return try await write()
        } catch where Self.provesZoneMissing(error) {
            printDebug("blobZone stale latch zone=\(zoneID.zoneName) recreating")
            resetZoneCreatedFlag()
            try await ensureZoneExists()
            return try await write()
        }
    }

    /// Whether `error` proves the zone named by the latch is gone. A record save
    /// reports it per item inside a partial failure rather than at the top level,
    /// so both shapes count.
    static func provesZoneMissing(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if isZoneMissingCode(ckError.code) { return true }
        return (ckError.partialErrorsByItemID ?? [:]).values.contains {
            guard let itemError = $0 as? CKError else { return false }
            return isZoneMissingCode(itemError.code)
        }
    }

    private static func isZoneMissingCode(_ code: CKError.Code) -> Bool {
        code == .zoneNotFound || code == .userDeletedZone
    }
}

// MARK: - CloudKit implementation

public final class CloudKitChunkedBlobStore: ChunkedBlobStoring, DebugPrintable, @unchecked Sendable {

    private let adapter: CloudKitDatabaseAdapter
    private let container: CloudKitContainer
    private let zoneID: CKRecordZone.ID
    private let zoneLatch: BlobZoneLatch

    /// CloudKit's documented ceiling is 200 records per request (and 200 asset
    /// tokens, which one-asset-per-chunk keeps aligned). 25 stays well under both and
    /// bounds the scratch directory: chunks are written, uploaded and deleted a batch
    /// at a time, so peak temp usage is `uploadBatchSize * chunkSize` — 100 MB at the
    /// 4 MiB production chunk, rather than a second copy of the whole video.
    private static let uploadBatchSize = 25

    public init(container: CloudKitContainer = .shared,
                adapter: CloudKitDatabaseAdapter? = nil,
                zoneProvisioner: RecordZoneProvisioning? = nil,
                defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard) {
        self.container = container
        self.adapter = adapter ?? CKDatabaseAdapter(database: container.privateDB)
        let zoneID = CKRecordZone.ID(zoneName: ChunkedBlobSchema.zoneName)
        self.zoneID = zoneID
        self.zoneLatch = BlobZoneLatch(zoneID: zoneID,
                                       zoneProvisioner: zoneProvisioner ?? container.privateDB,
                                       defaults: defaults)
    }

    // MARK: Zone

    public func ensureZoneExists() async throws {
        try await zoneLatch.ensureZoneExists()
    }

    /// Clears the persisted zone-created latch, so the next write re-issues the
    /// zone create. Called when a zone-level error proves the flag stale (the
    /// zone was deleted server-side) and by the destructive erase.
    public func resetZoneCreatedFlag() {
        zoneLatch.resetZoneCreatedFlag()
    }

    // MARK: Upload

    /// Which of this blob's chunk records already exist in the zone, by index.
    ///
    /// A metadata-only probe (`desiredKeys: []` — no asset transfer) over the
    /// computed record IDs, so a retried upload can skip every chunk a previous
    /// attempt already committed. Missing records surface either as absences in
    /// the result or as per-item `.unknownItem` errors inside a `.partialFailure`
    /// — both mean "not there yet". A zone that does not exist holds nothing.
    public func existingChunkIndices(mediaRecordName: String, chunkCount: Int) async throws -> Set<Int> {
        var existing: Set<Int> = []
        let allIndices = Array(0..<chunkCount)
        for batch in allIndices.chunked(into: Self.uploadBatchSize) {
            let ids = batch.map {
                CKRecord.ID(recordName: ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: $0),
                            zoneID: zoneID)
            }
            do {
                let found = try await adapter.fetch(recordIDs: ids,
                                                    desiredKeys: [],
                                                    qualityOfService: .userInitiated,
                                                    perRecordProgress: { _, _ in })
                for (offset, id) in ids.enumerated() where found[id] != nil {
                    existing.insert(batch[offset])
                }
            } catch let error as CKError where error.code == .partialFailure {
                if BlobZoneLatch.provesZoneMissing(error) {
                    resetZoneCreatedFlag()
                    return []
                }
                // Real CloudKit reports missing records as per-item `.unknownItem`
                // inside an op-level partial failure. Anything else in there is a
                // genuine fetch failure and must propagate.
                let perItem = error.partialErrorsByItemID ?? [:]
                let missing = Set(perItem.compactMap { key, value -> String? in
                    guard let recordID = key as? CKRecord.ID,
                          (value as? CKError)?.code == .unknownItem else { return nil }
                    return recordID.recordName
                })
                guard missing.count == perItem.count else { throw error }
                for (offset, id) in ids.enumerated() where !missing.contains(id.recordName) {
                    existing.insert(batch[offset])
                }
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                resetZoneCreatedFlag()
                return []
            }
        }
        return existing
    }

    @discardableResult
    public func uploadChunks(enc3FileURL: URL,
                             mediaRecordName: String,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
        guard await container.isCloudKitAvailable() else { throw ChunkedBlobError.accountUnavailable }
        try await ensureZoneExists()

        let (header, _) = try SeekableEncryptedHeader.read(fromFileAt: enc3FileURL)
        let geometry = header.geometry
        let total = geometry.chunkCount

        // Resume-by-probe: skip every chunk a previous attempt already committed.
        // Computed names + `.allKeys` make re-saving safe, but re-uploading 90% of
        // a 1 GB video because the connection dropped at 90% is what this avoids.
        let existing = try await existingChunkIndices(mediaRecordName: mediaRecordName, chunkCount: total)

        let handle = try FileHandle(forReadingFrom: enc3FileURL)
        defer { try? handle.close() }

        // Split the ENC3 file into one temp file per chunk. CKAsset can only be
        // constructed from a file URL, so the bytes have to land on disk regardless;
        // doing it in a scratch directory keeps the originals untouched and makes
        // cleanup a single removal. Built, uploaded and deleted one batch at a
        // time, so peak scratch is `uploadBatchSize * chunkSize`, not a second
        // copy of the whole video.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc3-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var pending: [CKRecord] = []
        var pendingFiles: [URL] = []
        var completed = existing.count

        // Per-record save progress, fanned into one overall fraction so a 4 MiB
        // batch entry moves the bar continuously instead of in 100 MB dead zones.
        // The lock is required: CloudKit invokes the progress closure on its own
        // callback queue.
        let progressLock = NSLock()
        var batchFractions: [CKRecord.ID: Double] = [:]

        func flush() async throws {
            guard !pending.isEmpty else { return }
            let completedSoFar = completed
            let batch = pending
            progressLock.withLock { batchFractions.removeAll(keepingCapacity: true) }
            let saved = try await zoneLatch.withZone {
                try await adapter.save(records: batch, savePolicy: .allKeys) { recordID, fraction in
                    let overall: Double = progressLock.withLock {
                        batchFractions[recordID] = fraction
                        let inFlight = batchFractions.values.reduce(0, +)
                        // +1 keeps the bar short of 100% until the caller's commit
                        // record (EncMedia) lands.
                        return (Double(completedSoFar) + inFlight) / Double(max(1, total + 1))
                    }
                    progress(overall)
                }
            }
            // Both saves used to discard results; a silently-dropped chunk then
            // surfaced weeks later as a mid-playback `chunkNotFound`. Fail loudly
            // here instead.
            guard saved.count == batch.count else {
                throw ChunkedBlobError.saveVerificationFailed(expected: batch.count, saved: saved.count)
            }
            completed += batch.count
            for file in pendingFiles { try? FileManager.default.removeItem(at: file) }
            pending.removeAll(keepingCapacity: true)
            pendingFiles.removeAll(keepingCapacity: true)
            progress(Double(completed) / Double(max(1, total + 1)))
        }

        for index in 0..<total where !existing.contains(index) {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(geometry.ciphertextOffset(ofChunk: index)))
            let want = geometry.ciphertextSize(ofChunk: index)
            guard let bytes = try handle.read(upToCount: want), bytes.count == want else {
                throw SeekableFormatError.chunkSizeMismatch(index: index, expected: want, got: 0)
            }
            let chunkURL = scratch.appendingPathComponent("c\(index).bin")
            try bytes.write(to: chunkURL)

            let recordID = CKRecord.ID(
                recordName: ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: index),
                zoneID: zoneID)
            let record = CKRecord(recordType: ChunkedBlobSchema.Chunk.recordType, recordID: recordID)
            record[ChunkedBlobSchema.Chunk.mediaRecordName] = mediaRecordName as CKRecordValue
            record[ChunkedBlobSchema.Chunk.chunkIndex] = Int64(index) as CKRecordValue
            record[ChunkedBlobSchema.Chunk.encChunk] = CKAsset(fileURL: chunkURL)
            record[ChunkedBlobSchema.Chunk.schemaVersion] = ChunkedBlobSchema.currentSchemaVersion as CKRecordValue
            pending.append(record)
            pendingFiles.append(chunkURL)

            if pending.count >= Self.uploadBatchSize { try await flush() }
        }
        try await flush()
        printDebug("uploadChunks ok media=\(mediaRecordName) chunks=\(total) skippedExisting=\(existing.count) bytes=\(geometry.plaintextLength)")
        return header
    }

    // MARK: Fetch

    /// Drops the snapshot the adapter staged, since a caller that wants only the
    /// bytes has no use for the file. Twenty chunks per video, so keeping them is
    /// how tmp grows by the size of every video ever played.
    public func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
        let chunk = try await fetchChunkStaged(mediaRecordName: mediaRecordName, index: index)
        CKDatabaseAdapter.discardSnapshot(at: chunk.stagedFileURL)
        return chunk.data
    }

    public func fetchChunkStaged(mediaRecordName: String, index: Int) async throws -> FetchedChunk {
        let recordID = CKRecord.ID(
            recordName: ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: index),
            zoneID: zoneID)
        // `.userInteractive` and a single-key `desiredKeys`: a chunk is only ever
        // fetched because a player is waiting on it, and the top QoS band is a real
        // throughput knob for asset transfers rather than a scheduling hint. The
        // default `.utility` opts into discretionary networking, which is a
        // documented cause of transfers that appear to hang.
        let records = try await adapter.fetch(recordIDs: [recordID],
                                              desiredKeys: [ChunkedBlobSchema.Chunk.encChunk],
                                              qualityOfService: .userInteractive,
                                              perRecordProgress: { _, _ in })
        guard let record = records[recordID] else {
            throw ChunkedBlobError.chunkNotFound("\(mediaRecordName)#c\(index)")
        }
        guard let asset = record[ChunkedBlobSchema.Chunk.encChunk] as? CKAsset,
              let fileURL = asset.fileURL else {
            throw ChunkedBlobError.chunkAssetMissing("\(mediaRecordName)#c\(index)")
        }
        // Read immediately. On iOS 18+ a CKAsset's cache file is only guaranteed
        // valid until the delivery closure returns, and the system may reclaim it at
        // any point after that.
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            CKDatabaseAdapter.discardSnapshot(at: fileURL)
            throw error
        }
        // Only the adapter's own snapshot may be handed over. When the snapshot copy
        // failed the asset still points at CloudKit's staged file, which this process
        // does not own and must neither move nor delete.
        guard CKDatabaseAdapter.isSnapshot(fileURL) else {
            return FetchedChunk(data: data, stagedFileURL: nil)
        }
        return FetchedChunk(data: data, stagedFileURL: fileURL)
    }

    // MARK: Delete

    public func delete(mediaRecordName: String, chunkCount: Int) async throws {
        let ids = (0..<chunkCount).map {
            CKRecord.ID(recordName: ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: $0),
                        zoneID: zoneID)
        }
        for batch in ids.chunked(into: Self.uploadBatchSize) {
            do {
                _ = try await adapter.delete(recordIDs: batch)
            } catch let error where Self.isAlreadyAbsent(error) {
                // Nothing to delete is success for a delete: a retried cleanup
                // re-deletes chunks a prior pass already removed, and that may not
                // fail the operation.
                continue
            }
        }
    }

    /// Whether a delete failure only says "those records were already gone".
    static func isAlreadyAbsent(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .unknownItem, .zoneNotFound, .userDeletedZone:
            return true
        case .partialFailure:
            let perItem = ckError.partialErrorsByItemID ?? [:]
            return !perItem.isEmpty && perItem.values.allSatisfy { isAlreadyAbsent($0) }
        default:
            return false
        }
    }
}

// MARK: - In-memory implementation

/// Backs unit tests and any simulator run: same semantics, no container.
public actor InMemoryChunkedBlobStore: ChunkedBlobStoring {
    private var chunks: [String: Data] = [:]
    /// Every chunk index this store has been asked for, in order — the evidence a
    /// test needs to prove a seek fetched only what it needed.
    public private(set) var fetchLog: [(media: String, index: Int)] = []
    /// Artificial per-chunk latency, so a test can make "streamed before fully
    /// downloaded" observable without a network.
    public var chunkLatency: Duration = .zero

    public init() {}

    public func setChunkLatency(_ latency: Duration) { chunkLatency = latency }
    public func resetLog() { fetchLog = [] }
    public var fetchedIndices: [Int] { fetchLog.map(\.index) }

    @discardableResult
    public func uploadChunks(enc3FileURL: URL,
                             mediaRecordName: String,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
        let reader = try SeekableEncryptedReader.forFile(enc3FileURL, keyBytes: [UInt8](repeating: 0, count: 32))
        let header = reader.header
        let geometry = header.geometry
        let handle = try FileHandle(forReadingFrom: enc3FileURL)
        defer { try? handle.close() }
        for index in 0..<geometry.chunkCount {
            try handle.seek(toOffset: UInt64(geometry.ciphertextOffset(ofChunk: index)))
            let want = geometry.ciphertextSize(ofChunk: index)
            let bytes = try handle.read(upToCount: want) ?? Data()
            chunks[ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: index)] = bytes
            progress(Double(index + 1) / Double(max(1, geometry.chunkCount)))
        }
        return header
    }

    public func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
        fetchLog.append((media: mediaRecordName, index: index))
        if chunkLatency > .zero { try await Task.sleep(for: chunkLatency) }
        let name = ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: index)
        guard let data = chunks[name] else { throw ChunkedBlobError.chunkNotFound(name) }
        return data
    }

    public func delete(mediaRecordName: String, chunkCount: Int) async throws {
        for index in 0..<chunkCount {
            chunks[ChunkedBlobSchema.chunkRecordName(mediaRecordName: mediaRecordName, index: index)] = nil
        }
    }
}

// `Array.chunked(into:)` comes from MediaImportHandler.swift — same module, so
// batching here reuses it rather than declaring a second copy.
