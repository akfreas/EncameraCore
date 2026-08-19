//
//  CloudKitFoundationsTests.swift
//  EncameraCoreTests
//
//  Chunk 01 — CloudKit foundations. These tests never touch a live iCloud
//  account: account status and zone provisioning are injected via stubs.
//

import XCTest
import CloudKit
@testable import EncameraCore

final class CloudKitFoundationsTests: XCTestCase {

    // MARK: - Stubs

    private struct StubAccountStatus: AccountStatusProviding {
        let status: CKAccountStatus
        func currentAccountStatus() async throws -> CKAccountStatus { status }
    }

    private final class CountingZoneProvisioner: RecordZoneProvisioning {
        private(set) var saveCount = 0
        private(set) var deletedZoneIDs: [CKRecordZone.ID] = []
        var deleteError: Error?
        func saveZone(_ zone: CKRecordZone) async throws { saveCount += 1 }
        func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
            deletedZoneIDs.append(zoneID)
            if let deleteError { throw deleteError }
        }
    }

    // A throwaway, isolated defaults suite so the persisted "zone created" flag
    // never leaks between tests, into the app group, or across runs.
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        makeIsolatedDefaults(name)
    }

    private func makeKeyedHandler(keyBytes: [UInt8]) -> SyncedStoreEncryptionHandler {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "test", keyBytes: keyBytes, creationDate: Date())
        return SyncedStoreEncryptionHandler(keyManager: keyManager)
    }

    // MARK: - Schema constants are stable

    func testSchemaConstantsAreStable() {
        // One container shared by both bundle IDs; debug/prod isolation is by
        // CloudKit environment, not container.
        XCTAssertEqual(CloudKitSchema.containerID, "iCloud.app.encamera.Encamera")
        XCTAssertEqual(CloudKitSchema.zoneName, "EncameraZone")
        XCTAssertEqual(CloudKitSchema.EncMedia.recordType, "EncMedia")
        XCTAssertEqual(CloudKitSchema.EncMedia.albumID, "albumID")
        XCTAssertEqual(CloudKitSchema.EncMedia.mediaID, "mediaID")
        XCTAssertEqual(CloudKitSchema.EncMedia.mediaType, "mediaType")
        XCTAssertEqual(CloudKitSchema.EncMedia.createdAt, "createdAt")
        XCTAssertEqual(CloudKitSchema.EncMedia.sizeBytes, "sizeBytes")
        XCTAssertEqual(CloudKitSchema.EncMedia.creationDevice, "creationDeviceID")
        XCTAssertEqual(CloudKitSchema.EncMedia.schemaVersion, "schemaVersion")
        XCTAssertEqual(CloudKitSchema.EncMedia.encThumbnail, "encThumbnail")
        XCTAssertEqual(CloudKitSchema.EncMedia.encBlob, "encBlob")
    }

    // MARK: - Account status gating

    func testAccountStatusUnavailableFallsBackToLocal() async {
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .noAccount),
            zoneProvisioner: CountingZoneProvisioner(),
            defaults: freshDefaults()
        )

        // Never throws, reports the underlying status, and is treated as unavailable.
        let status = await container.accountStatus()
        XCTAssertEqual(status, .noAccount)

        let available = await container.isCloudKitAvailable()
        XCTAssertFalse(available)
    }

    func testAccountStatusAvailableReportsAvailable() async {
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: CountingZoneProvisioner(),
            defaults: freshDefaults()
        )
        let available = await container.isCloudKitAvailable()
        XCTAssertTrue(available)
    }

    // MARK: - Zone bootstrap idempotency

    func testEnsureZoneIsIdempotent() async throws {
        let provisioner = CountingZoneProvisioner()
        let defaults = freshDefaults()
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: defaults
        )

        try await container.ensureZoneExists()
        try await container.ensureZoneExists()
        try await container.ensureZoneExists()

        // The persisted flag short-circuits every call after the first success.
        XCTAssertEqual(provisioner.saveCount, 1)
    }

    // MARK: - Teardown (Erase All Data)

    func testDeleteAllCloudDataDeletesZoneAndResetsFlag() async throws {
        let provisioner = CountingZoneProvisioner()
        let defaults = freshDefaults()
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: defaults
        )

        // Prime the "zone created" flag so we can prove the teardown clears it.
        try await container.ensureZoneExists()
        XCTAssertEqual(provisioner.saveCount, 1)

        try await container.deleteAllCloudData()

        XCTAssertEqual(provisioner.deletedZoneIDs, [container.zoneID])

        // Flag was reset: the next ensureZoneExists re-provisions instead of short-circuiting.
        try await container.ensureZoneExists()
        XCTAssertEqual(provisioner.saveCount, 2)
    }

    func testDeleteAllCloudDataTreatsZoneNotFoundAsSuccess() async throws {
        let provisioner = CountingZoneProvisioner()
        provisioner.deleteError = CKError(.zoneNotFound)
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: freshDefaults()
        )

        // A user who never used CloudKit must not see this surface as a failure.
        try await container.deleteAllCloudData()
        XCTAssertEqual(provisioner.deletedZoneIDs.count, 1)
    }

    func testDeleteAllCloudDataRethrowsRealError() async {
        let provisioner = CountingZoneProvisioner()
        provisioner.deleteError = CKError(.networkUnavailable)
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: freshDefaults()
        )

        do {
            try await container.deleteAllCloudData()
            XCTFail("Expected a non-benign CloudKit error to propagate")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkUnavailable)
        }
    }

    // MARK: - albumID determinism

    func testAlbumIDIsDeterministic() throws {
        let keyBytes: [UInt8] = Array(0..<32).map { UInt8($0) }
        let handlerA = makeKeyedHandler(keyBytes: keyBytes)
        let handlerB = makeKeyedHandler(keyBytes: keyBytes)

        let albumName = "Vacation 2024"
        let hashA = try handlerA.hashPrimaryKey(albumName)
        let hashB = try handlerB.hashPrimaryKey(albumName)

        // Same key + same album name => same albumID across instances (devices).
        XCTAssertEqual(hashA, hashB)
        // A different album name must not collide.
        let other = try handlerA.hashPrimaryKey("Work")
        XCTAssertNotEqual(hashA, other)
    }
}
