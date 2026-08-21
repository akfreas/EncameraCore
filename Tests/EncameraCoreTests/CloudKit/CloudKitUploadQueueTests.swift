//
//  CloudKitUploadQueueTests.swift
//  EncameraCoreTests
//
//  The holding folder is the only copy of a capture until CloudKit confirms it,
//  so every deletion path in the queue is a data-loss path. These tests pin the
//  behaviours that keep it safe — above all that `sweep()` never treats a file
//  as an orphan just because the manifest describing it could not be read.
//

import XCTest
@testable import EncameraCore

final class CloudKitUploadQueueTests: XCTestCase {

    private var baseDir: URL!

    override func setUp() {
        super.setUp()
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: baseDir)
        super.tearDown()
    }

    private func makeUpload(mediaID: String = UUID().uuidString,
                            recordName: String? = nil,
                            contents: String = "ciphertext",
                            keyFingerprint: String = "") throws -> CloudKitMediaUpload {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap-\(UUID().uuidString).photo")
        try Data(contents.utf8).write(to: src)
        return CloudKitMediaUpload(albumID: "album1",
                                   mediaID: mediaID,
                                   mediaType: .photo,
                                   createdAt: Date(),
                                   sizeBytes: Int64(contents.utf8.count),
                                   encryptedFileURL: src,
                                   encryptedThumbURL: nil,
                                   recordName: recordName ?? "\(mediaID)#0",
                                   keyFingerprint: keyFingerprint)
    }

    // MARK: - Sweep safety

    /// The failure this guards against: a schema change to `CloudKitPendingUpload`
    /// (or plain corruption) makes the whole manifest undecodable, `loadIfNeeded`
    /// starts empty, and the launch sweep then sees every pending capture as an
    /// unclaimed orphan — and deletes the only copy of the user's photos.
    func testSweepKeepsFilesWhenManifestIsUnreadable() async throws {
        let seed = CloudKitUploadQueue(baseDir: baseDir)
        let queued = try await seed.enqueue(makeUpload())
        XCTAssertTrue(FileManager.default.fileExists(atPath: queued.encryptedFileURL.path))

        try Data("not json".utf8).write(to: baseDir.appendingPathComponent("queue.json"))

        // Fresh instance over the same directory = next launch.
        let relaunched = CloudKitUploadQueue(baseDir: baseDir)
        await relaunched.sweep()

        XCTAssertTrue(FileManager.default.fileExists(atPath: queued.encryptedFileURL.path),
                      "sweep() must not delete a pending capture just because the manifest is unreadable")
    }

    /// One drifted entry must cost that entry's metadata, not the manifest: the
    /// decodable entries are salvaged, and — because something WAS dropped —
    /// orphan deletion stays off so the dropped entry's file survives too.
    func testSalvagesDecodableEntriesFromDriftedManifest() async throws {
        let seed = CloudKitUploadQueue(baseDir: baseDir)
        let queued = try await seed.enqueue(makeUpload(mediaID: "GOOD"))

        let manifestURL = baseDir.appendingPathComponent("queue.json")
        var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [[String: Any]]
        entries.append(["schemaFromTheFuture": true])
        try JSONSerialization.data(withJSONObject: entries).write(to: manifestURL)

        let relaunched = CloudKitUploadQueue(baseDir: baseDir)
        let next = await relaunched.next()
        XCTAssertEqual(next?.recordName, "GOOD#0", "The decodable entry must survive a drifted manifest")

        await relaunched.sweep()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queued.encryptedFileURL.path),
                      "A partially-readable manifest must not turn claimed files into deletable orphans")
    }

    /// The healthy-manifest housekeeping still works: files nothing claims move
    /// to quarantine (not straight to deletion — sweep is the queue's one
    /// destructive operation on user media, and a matching bug here has already
    /// destroyed a pending photo once), and records whose file vanished are
    /// dropped.
    func testSweepQuarantinesOrphansAndDropsMissingRecordsWithHealthyManifest() async throws {
        let queue = CloudKitUploadQueue(baseDir: baseDir)
        let kept = try await queue.enqueue(makeUpload(mediaID: "KEPT"))
        let doomed = try await queue.enqueue(makeUpload(mediaID: "DOOMED"))

        // An orphan file no record claims, and a record whose file vanished.
        let albumDir = doomed.encryptedFileURL.deletingLastPathComponent()
        let orphan = albumDir.appendingPathComponent("orphan.photo")
        try Data("stray".utf8).write(to: orphan)
        try FileManager.default.removeItem(at: doomed.encryptedFileURL)

        await queue.sweep()

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.encryptedFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "Unclaimed files leave the album folder when the manifest is healthy")
        let quarantined = baseDir.appendingPathComponent(CloudKitUploadQueue.quarantineFolderName)
            .appendingPathComponent("\(albumDir.lastPathComponent)-orphan.photo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path), "An orphan is quarantined, not deleted")
        let remaining = await queue.all().map(\.mediaID)
        XCTAssertEqual(remaining, ["KEPT"], "A record whose file vanished is dropped")
    }

    // MARK: - Manifest compatibility

    /// A manifest entry written before the fingerprint was required does not decode, and
    /// the queue drops it rather than migrating it. Nothing has ever shipped a CloudKit
    /// build, so the only such manifests are on development devices, and an entry that
    /// cannot say which key wrote its bytes has nothing it could legitimately publish.
    func testManifestWithoutKeyFingerprintIsDiscarded() throws {
        let legacy = """
        [{"albumID":"a1","mediaID":"m1","recordName":"m1#0","mediaTypeRawValue":0,\
        "createdAt":0,"sizeBytes":1,"fileName":"m1.encrypted","queuedAt":0,\
        "attempts":0,"hasGivenUp":false}]
        """
        let decoded = try? JSONDecoder().decode([CloudKitPendingUpload].self,
                                                from: Data(legacy.utf8))
        XCTAssertNil(decoded, "a pre-requirement entry must not decode into a publishable upload")
    }

    /// The doc comment's claim on `keyFingerprint` — "carried across a relaunch so a
    /// retried upload still stamps `EncMedia.keyFingerprint`" — proven end to end.
    func testKeyFingerprintSurvivesRelaunch() async throws {
        let seed = CloudKitUploadQueue(baseDir: baseDir)
        try await seed.enqueue(makeUpload(mediaID: "STAMPED", keyFingerprint: "abc123"))

        let relaunched = CloudKitUploadQueue(baseDir: baseDir)
        let next = await relaunched.next()
        let item = try XCTUnwrap(next)
        let rebuilt = await relaunched.rebuild(item, thumbURL: nil)
        XCTAssertEqual(rebuilt.keyFingerprint, "abc123",
                       "A retried upload after relaunch must still stamp the record")
    }

    // MARK: - Lifecycle

    func testCompleteAndCancelRemoveTheDurableCopy() async throws {
        let queue = CloudKitUploadQueue(baseDir: baseDir)
        let completed = try await queue.enqueue(makeUpload(mediaID: "DONE"))
        let cancelled = try await queue.enqueue(makeUpload(mediaID: "GONE"))

        await queue.complete(recordName: "DONE#0")
        let wasPending = await queue.cancel(recordName: "GONE#0")

        XCTAssertTrue(wasPending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.encryptedFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.encryptedFileURL.path))
        let count = await queue.waitingCount()
        XCTAssertEqual(count, 0)

        let unknown = await queue.cancel(recordName: "NEVER#0")
        XCTAssertFalse(unknown, "Cancelling an unknown record must report that nothing was pending")
    }
}
