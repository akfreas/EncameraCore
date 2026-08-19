//
//  DestructiveOnboardingTests.swift
//  EncameraCoreTests
//
//  The destructive delete-my-iCloud-data path (ENC-94). The riskiest flow in the
//  project — it deletes user data by design and sits on the tombstone landmine
//  (ENC-72/ENC-82). These tests pin the non-negotiables:
//   * every record and album is tombstoned,
//   * a partial failure is reported, never swallowed into a false success,
//   * NO account-wide keychain deletion is ever issued (the landmine),
//   * a fresh key is minted only on a clean run,
//   * the has-used marker is cleared while the device roster survives.
//

import XCTest
import Foundation
@testable import EncameraCore

final class DestructiveOnboardingTests: XCTestCase {

    // MARK: - Helpers

    private func album(_ id: String) -> CloudKitAlbumMetadata {
        CloudKitAlbumMetadata(albumID: id, encName: "enc-\(id)", createdAt: Date(),
                              isHidden: false, deletedAt: nil,
                              schemaVersion: CloudKitSchema.currentSchemaVersion,
                              keyFingerprint: nil,
                              recordChangeTag: "tag")
    }

    private func media(_ recordName: String, albumID: String) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: recordName, albumID: albumID, mediaID: recordName,
                              mediaType: .photo, createdAt: Date(), sizeBytes: 1,
                              creationDeviceID: "dev", deletedAt: nil,
                              schemaVersion: CloudKitSchema.currentSchemaVersion,
                              recordChangeTag: "tag")
    }

    /// A store seeded with one album and three live media records.
    private func seededStore() -> MockCloudKitMediaStore {
        let store = MockCloudKitMediaStore()
        store.seedAlbum(album("album-1"))
        store.metadataToReturn = [media("m1", albumID: "album-1"),
                                  media("m2", albumID: "album-1"),
                                  media("m3", albumID: "album-1")]
        return store
    }

    private func makeCoordinator(store: CloudKitMediaStoring,
                                 keyManager: KeyManager) -> DestructiveOnboardingCoordinator {
        // Inject an inert legacy-file remover so these tests never touch the disk.
        DestructiveOnboardingCoordinator(store: store,
                                         keyManager: keyManager,
                                         removeLegacyICloudDriveFiles: { (0, nil) })
    }

    // MARK: - Tests

    func testDeletionTombstonesAllRecords() async throws {
        let store = seededStore()
        let keyManager = DestructiveSpyKeyManager()

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 3)

        XCTAssertTrue(report.isCompleteSuccess, "A clean run must report success")
        XCTAssertEqual(Set(store.tombstoneCalls), ["m1", "m2", "m3"],
                       "Every media record must be tombstoned")
        XCTAssertEqual(store.tombstonedAlbumCalls, ["album-1"],
                       "The album must be tombstoned")
        XCTAssertEqual(Set(report.tombstonedMedia), ["m1", "m2", "m3"])
        XCTAssertEqual(report.tombstonedAlbums, ["album-1"])
    }

    func testPartialDeletionFailureIsReported() async throws {
        let store = seededStore()
        store.deleteError = CloudKitMediaStoreError.notFound   // tombstones now fail
        let keyManager = DestructiveSpyKeyManager()

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 3)

        XCTAssertFalse(report.isCompleteSuccess, "A failed tombstone must not be reported as success")
        XCTAssertTrue(report.hasFailures)
        XCTAssertFalse(report.mediaFailures.isEmpty, "Per-record failures must be surfaced, not swallowed")
        // A partial failure must NOT clear the marker or mint a key.
        XCTAssertFalse(report.freshKeyGenerated)
        XCTAssertTrue(keyManager.generatedKeyNames.isEmpty,
                      "No fresh key may be created when deletion did not fully succeed")
    }

    /// THE landmine regression: the destructive path must never issue an
    /// account-wide keychain deletion (it would tombstone the other device's key).
    func testDeletionDoesNotClearSyncedKeychainItems() async throws {
        let store = seededStore()
        let keyManager = DestructiveSpyKeyManager()

        _ = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 3)

        XCTAssertTrue(keyManager.clearScopes.isEmpty,
                      "The destructive path must issue NO keychain deletion at all")
        XCTAssertFalse(keyManager.clearScopes.contains(.accountWide),
                       "The destructive path must NEVER issue an account-wide keychain deletion")
    }

    func testFreshKeyGeneratedAfterDeletion() async throws {
        let store = seededStore()
        let keyManager = DestructiveSpyKeyManager()
        XCTAssertEqual(try keyManager.storedKeys().count, 0)

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 3)

        XCTAssertTrue(report.freshKeyGenerated)
        XCTAssertEqual(keyManager.generatedKeyNames, [AppConstants.defaultKeyName],
                       "A fresh default key must be generated after a clean deletion")
        XCTAssertEqual(try keyManager.storedKeys().count, 1,
                       "The fresh key must be persisted")
    }

    func testHasUsedMarkerClearedRosterPreserved() async throws {
        let store = seededStore()
        let keyManager = DestructiveSpyKeyManager()

        // Seed a returning-user record: marker set, one roster device, one fingerprint.
        let device = MultiDeviceState.DeviceRecord(deviceID: "other-device", name: "iPad", lastSeen: Date())
        try keyManager.setMultiDeviceState(
            MultiDeviceState(hasUsedEncamera: true, devices: [device], keyFingerprints: ["oldfingerprint"])
        )

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 3)
        XCTAssertTrue(report.isCompleteSuccess)

        let state = try XCTUnwrap(keyManager.getMultiDeviceState())
        XCTAssertFalse(state.hasUsedEncamera,
                       "The has-used marker must be cleared — proving the non-merging overwrite, not the OR-merge, was used")
        XCTAssertTrue(state.keyFingerprints.isEmpty,
                      "This account's fingerprints must be cleared")
        XCTAssertEqual(state.devices.map(\.deviceID), ["other-device"],
                       "The device roster must be preserved")
    }

    // MARK: - Enumeration failures must not read as "nothing to delete"

    /// The vacuous-success path: `fetchAllAlbums` throws (CloudKit throttling, a
    /// network drop after `accountAvailable()` returned true, query-index latency),
    /// which used to degrade to `[]` — so nothing was iterated, nothing failed,
    /// `isCompleteSuccess` was true, and the marker was cleared plus a fresh key
    /// minted over media still sitting in CloudKit, with the fingerprint that could
    /// have warned the user on the next install erased from the synced record.
    func testAlbumEnumerationFailureIsNotACompleteSuccess() async throws {
        let store = seededStore()
        store.fetchAllAlbumsError = CloudKitMediaStoreError.accountUnavailable
        let keyManager = DestructiveSpyKeyManager()
        let device = MultiDeviceState.DeviceRecord(deviceID: "other-device", name: "iPad", lastSeen: Date())
        try keyManager.setMultiDeviceState(
            MultiDeviceState(hasUsedEncamera: true, devices: [device], keyFingerprints: ["oldfingerprint"])
        )

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 3)

        XCTAssertFalse(report.isCompleteSuccess,
                       "Failing to enumerate what to delete must never report a complete success")
        XCTAssertNotNil(report.enumerationFailures["albums"])
        XCTAssertFalse(report.freshKeyGenerated, "No fresh key over data we never enumerated")
        XCTAssertEqual(keyManager.generatedKeyNames, [])
        XCTAssertEqual(store.tombstoneCalls, [], "Nothing was enumerated, so nothing may be tombstoned")

        let state = try XCTUnwrap(keyManager.getMultiDeviceState())
        XCTAssertTrue(state.hasUsedEncamera,
                      "The has-used marker must survive — it is the returning-user warning for the next install")
        XCTAssertEqual(state.keyFingerprints, ["oldfingerprint"],
                       "The fingerprint that can still decrypt the surviving media must not be erased")
    }

    /// Same distinction one level down: the album list arrives but its media
    /// enumeration fails. The album is skipped rather than silently treated as
    /// empty, and the run stops short of the marker clear.
    func testMediaEnumerationFailureIsNotACompleteSuccess() async throws {
        let store = seededStore()
        store.fetchMetadataError = CloudKitMediaStoreError.accountUnavailable
        let keyManager = DestructiveSpyKeyManager()

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 3)

        XCTAssertFalse(report.isCompleteSuccess)
        XCTAssertNotNil(report.enumerationFailures["album-1"])
        XCTAssertEqual(report.tombstonedMedia, [], "No media was enumerated, so none may be reported tombstoned")
        XCTAssertFalse(report.freshKeyGenerated)
    }

    /// The legacy-container twin of the same bug: an unreadable iCloud Drive
    /// container used to return `(0, nil)` — byte-for-byte the "nothing to remove"
    /// answer — and the run went on to clear the marker over files it never saw.
    func testUnreadableLegacyContainerIsNotACompleteSuccess() async throws {
        let store = seededStore()
        let keyManager = DestructiveSpyKeyManager()
        let coordinator = DestructiveOnboardingCoordinator(
            store: store,
            keyManager: keyManager,
            removeLegacyICloudDriveFiles: { (0, "could not enumerate the legacy iCloud Drive container") }
        )

        let report = try await coordinator.run(expectedMediaCount: 3)

        XCTAssertFalse(report.isCompleteSuccess)
        XCTAssertFalse(report.freshKeyGenerated)
    }

    // MARK: - The sweep is cross-checked against the census

    /// The quiet half of the vacuous-success bug: `fetchAllAlbums` does not throw,
    /// it simply comes back SHORT. `CKQuery` is not strongly consistent, so a stale
    /// `EncAlbum` index (or media whose album another device hard-deleted) yields an
    /// empty album list. Nothing iterates, nothing fails — and without a census
    /// cross-check the run reports clean success over media still in CloudKit.
    func testShortSweepAgainstCensusIsNotACompleteSuccess() async throws {
        let store = MockCloudKitMediaStore()      // no albums: the stale-index case
        // The zone still holds the census's records, so the delete cannot be verified.
        store.fingerprintCensusOverride = .counted(mediaCount: 47, fingerprints: [:])
        let keyManager = DestructiveSpyKeyManager()
        try keyManager.setMultiDeviceState(
            MultiDeviceState(hasUsedEncamera: true, devices: [], keyFingerprints: ["oldfingerprint"])
        )

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 47)

        XCTAssertFalse(report.isCompleteSuccess,
                       "Tombstoning nothing while the census says 47 must never report success")
        XCTAssertEqual(report.censusShortfall, 47)
        XCTAssertFalse(report.freshKeyGenerated, "No fresh key over media we never reached")
        XCTAssertEqual(keyManager.generatedKeyNames, [])

        let state = try XCTUnwrap(keyManager.getMultiDeviceState())
        XCTAssertTrue(state.hasUsedEncamera,
                      "The marker must survive — it is the next install's returning-user warning")
        XCTAssertEqual(state.keyFingerprints, ["oldfingerprint"],
                       "The fingerprints that can still decrypt the surviving media must not be erased")
    }

    /// The other side of that gate: the census itself was stale (the records really
    /// are gone), so a post-sweep census confirms an empty zone and the run
    /// completes. Without this the user could never finish the erase — every retry
    /// would fail against a number that can no longer be reached.
    func testShortSweepSucceedsWhenCensusConfirmsEmptyZone() async throws {
        let store = MockCloudKitMediaStore()      // no albums, and no live records
        let keyManager = DestructiveSpyKeyManager()

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 47)

        XCTAssertNil(report.censusShortfall,
                     "A confirmed-empty zone settles the shortfall — the census was the stale party")
        XCTAssertTrue(report.isCompleteSuccess)
        XCTAssertTrue(report.freshKeyGenerated)
    }

    func testEraseCompletesWhenTheZoneIsGone() async throws {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusError = CloudKitMediaStoreError.zoneNotFound
        let keyManager = DestructiveSpyKeyManager()
        try keyManager.setMultiDeviceState(
            MultiDeviceState(hasUsedEncamera: true, devices: [], keyFingerprints: ["oldfingerprint"])
        )

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 12)

        XCTAssertTrue(report.enumerationFailures.isEmpty, "A missing zone is not an enumeration failure")
        XCTAssertNil(report.censusShortfall,
                     "A zone that does not exist is provably empty — nothing is left unaccounted for")
        XCTAssertTrue(report.isCompleteSuccess)
        XCTAssertTrue(report.freshKeyGenerated)

        let state = try XCTUnwrap(keyManager.getMultiDeviceState())
        XCTAssertFalse(state.hasUsedEncamera, "A clean run clears the marker")
        XCTAssertEqual(state.keyFingerprints, [], "A clean run clears the fingerprints")
    }

    /// An unavailable index is not a confirmation. It is the same evidence-vs-absence
    /// distinction the probe makes, applied to verifying a delete.
    func testUnverifiableCensusDoesNotForgiveAShortSweep() async throws {
        let store = MockCloudKitMediaStore()
        store.fingerprintCensusOverride = .indexUnavailable
        let keyManager = DestructiveSpyKeyManager()

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 10)

        XCTAssertEqual(report.censusShortfall, 10)
        XCTAssertFalse(report.isCompleteSuccess)
        XCTAssertFalse(report.freshKeyGenerated)
    }

    // MARK: - The marker clear is the one write success is claimed over

    /// It used to be a `try?`: the write that `isCompleteSuccess` asserts happened
    /// could fail silently, and the run would still mint a fresh key over a record
    /// that still said `hasUsedEncamera: true` with the old fingerprints. The user
    /// then finished onboarding on the new key and was dropped back onto the
    /// returning-user branch at the next launch, for data they had already deleted.
    func testMarkerClearFailureIsReportedAndStopsShortOfTheMint() async throws {
        let store = seededStore()
        let keyManager = DestructiveSpyKeyManager()
        keyManager.overwriteError = CloudKitMediaStoreError.notFound

        let report = try await makeCoordinator(store: store, keyManager: keyManager).run(expectedMediaCount: 3)

        XCTAssertFalse(report.isCompleteSuccess,
                       "A failed marker clear must not read as a complete success")
        XCTAssertNotNil(report.markerClearError)
        XCTAssertFalse(report.freshKeyGenerated)
        XCTAssertEqual(keyManager.generatedKeyNames, [],
                       "No key may be minted over a marker that still says the account was used")
    }
}

/// A `DemoKeyManager` that records the blast radius of any keychain deletion and
/// actually persists a generated key, so the destructive-path assertions above
/// have something concrete to check.
private final class DestructiveSpyKeyManager: DemoKeyManager {
    var clearScopes: [KeyDeletionScope] = []
    var generatedKeyNames: [String] = []
    /// Injects a failing marker overwrite (an encode failure, or a non-`errSecSuccess`
    /// add/update out of `writeMultiDeviceStateRecord`).
    var overwriteError: Error?

    override func clearKeychainData(scope: KeyDeletionScope) {
        clearScopes.append(scope)
    }

    override func overwriteMultiDeviceState(_ state: MultiDeviceState) throws {
        if let overwriteError { throw overwriteError }
        try super.overwriteMultiDeviceState(state)
    }

    override func generateKeyUsingRandomWords(name: String) throws -> PrivateKey {
        generatedKeyNames.append(name)
        let key = PrivateKey(name: name,
                             keyBytes: Array((0..<32).map { _ in UInt8.random(in: 0...255) }),
                             creationDate: Date())
        storedKeysValue.append(key)
        return key
    }
}
