//
//  UserDefaultsKVSTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class UserDefaultsKVSTests: XCTestCase {

    private let testKey = "encamera_kvs_test_\(UUID().uuidString)"

    override func tearDown() {
        super.tearDown()
        let defaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
        defaults.removeObject(forKey: testKey)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: testKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    // MARK: - KVS entitlement

    /// Without `com.apple.developer.ubiquity-kvstore-identifier` in the
    /// entitlements, every KVS write is silently discarded and reads return nil.
    /// This test writes a value and reads it back — it passes only when the
    /// entitlement is present in the signed build.
    func testKVSEntitlementAllowsWriteAndReadBack() {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set("entitlement-probe", forKey: testKey)
        kvs.synchronize()

        let readBack = kvs.string(forKey: testKey)
        XCTAssertEqual(readBack, "entitlement-probe",
                       "KVS write/read failed — is com.apple.developer.ubiquity-kvstore-identifier present in the entitlements?")
    }

    // MARK: - Local-first reads

    /// Reads must come from local UserDefaults, not from
    /// NSUbiquitousKeyValueStore. Write different values to each store and
    /// verify the read returns the local value.
    func testReadReturnsLocalValueNotCloudValue() {
        let defaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
        let kvs = NSUbiquitousKeyValueStore.default

        defaults.set("local-value", forKey: UserDefaultKey.savedSettings.rawValue)
        kvs.set("cloud-value", forKey: UserDefaultKey.savedSettings.rawValue)
        kvs.synchronize()

        let result = UserDefaultUtils.value(forKey: .savedSettings)
        XCTAssertEqual(result as? String, "local-value",
                       "UserDefaultUtils.value(forKey:) must read from local defaults, not cloud store")

        defaults.removeObject(forKey: UserDefaultKey.savedSettings.rawValue)
        kvs.removeObject(forKey: UserDefaultKey.savedSettings.rawValue)
        kvs.synchronize()
    }

    func testBoolNullableReturnsLocalValue() {
        let defaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
        let kvs = NSUbiquitousKeyValueStore.default
        let key = UserDefaultKey.hasOpenedAlbum

        defaults.set(true, forKey: key.rawValue)
        kvs.set(false, forKey: key.rawValue)
        kvs.synchronize()

        let result = UserDefaultUtils.boolNullable(forKey: key)
        XCTAssertEqual(result, true,
                       "boolNullable must read from local defaults, not cloud store")

        defaults.removeObject(forKey: key.rawValue)
        kvs.removeObject(forKey: key.rawValue)
        kvs.synchronize()
    }

    func testIntegerReturnsLocalValue() {
        let defaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
        let kvs = NSUbiquitousKeyValueStore.default
        let key = UserDefaultKey.gridZoomLevel

        defaults.set(3, forKey: key.rawValue)
        kvs.set(Int64(7), forKey: key.rawValue)
        kvs.synchronize()

        let result = UserDefaultUtils.integer(forKey: key)
        XCTAssertEqual(result, 3,
                       "integer(forKey:) must read from local defaults, not cloud store")

        defaults.removeObject(forKey: key.rawValue)
        kvs.removeObject(forKey: key.rawValue)
        kvs.synchronize()
    }

    // MARK: - shouldSyncToiCloud

    func testShouldSyncToiCloudForSyncableKeys() {
        let syncable: [UserDefaultKey] = [
            .onboardingState, .savedSettings, .currentAlbumID,
            .showCurrentAlbumOnLaunch, .defaultStorageLocation,
            .gridZoomLevel, .gridSortOption, .currentKey
        ]
        for key in syncable {
            XCTAssertTrue(key.shouldSyncToiCloud,
                          "\(key.rawValue) should be syncable")
        }
    }

    func testShouldSyncToiCloudRejectsLocalOnlyKeys() {
        let localOnly: [UserDefaultKey] = [
            .capturedPhotos, .viewGalleryCount, .reviewRequestedMetric,
            .lockoutEnd, .launchCountKey, .photoAddedCount,
            .videoAddedCount, .loopVideos, .fontFamily, .fontSizeOffset
        ]
        for key in localOnly {
            XCTAssertFalse(key.shouldSyncToiCloud,
                           "\(key.rawValue) should NOT be syncable")
        }
    }
}
