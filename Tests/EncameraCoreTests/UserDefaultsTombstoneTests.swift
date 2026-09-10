//
//  UserDefaultsTombstoneTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

/// The launch-time half of the defaults wipe: a tombstone left by a previous
/// Erase All Data clears whatever landed after that run's wipe.
final class UserDefaultsTombstoneTests: XCTestCase {

    private var groupDefaults: UserDefaults { UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard }
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "" }
    private var savedGroupDomain: [String: Any]?
    private var savedStandardDomain: [String: Any]?

    override func setUp() {
        super.setUp()
        savedGroupDomain = groupDefaults.persistentDomain(forName: UserDefaultUtils.appGroup)
        savedStandardDomain = UserDefaults.standard.persistentDomain(forName: bundleID)
    }

    override func tearDown() {
        UserDefaultUtils.writesQuiescedForErase = false
        groupDefaults.removePersistentDomain(forName: UserDefaultUtils.appGroup)
        if let savedGroupDomain { groupDefaults.setPersistentDomain(savedGroupDomain, forName: UserDefaultUtils.appGroup) }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        if let savedStandardDomain { UserDefaults.standard.setPersistentDomain(savedStandardDomain, forName: bundleID) }
        super.tearDown()
    }

    func testTombstoneWipesBothDomainsAndKeepsTheCloudWipeMarker() {
        groupDefaults.set("late", forKey: "wroteAfterErase")
        groupDefaults.set(true, forKey: UserDefaultKey.pendingCloudDataWipe.rawValue)
        groupDefaults.set(true, forKey: UserDefaultKey.pendingDefaultsWipe.rawValue)
        UserDefaults.standard.set(3, forKey: "standardDomainLeftover")

        UserDefaultUtils.checkTombstoneAndWipe()

        XCTAssertNil(groupDefaults.object(forKey: "wroteAfterErase"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "standardDomainLeftover"))
        XCTAssertNil(groupDefaults.object(forKey: UserDefaultKey.pendingDefaultsWipe.rawValue), "the tombstone is consumed")
        XCTAssertTrue(UserDefaultUtils.bool(forKey: .pendingCloudDataWipe), "the cloud-wipe retry still needs its marker")
    }

    func testNoTombstoneLeavesEverythingAlone() {
        groupDefaults.set("kept", forKey: "ordinarySetting")
        UserDefaults.standard.set(3, forKey: "standardDomainValue")

        UserDefaultUtils.checkTombstoneAndWipe()

        XCTAssertEqual(groupDefaults.string(forKey: "ordinarySetting"), "kept")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "standardDomainValue"), 3)
    }

    func testTombstoneIsLocalOnly() {
        XCTAssertFalse(UserDefaultKey.pendingDefaultsWipe.shouldSyncToiCloud,
                       "a synced tombstone would wipe every other device on the account at its next launch")
        XCTAssertTrue(UserDefaultUtils.localOnlyMarkerKeys.contains(UserDefaultKey.pendingDefaultsWipe.rawValue))
    }

    func testQuiescedWritesRefuseSettingsButKeepTheEraseMarkers() {
        UserDefaultUtils.quiesceWritesForErase()

        UserDefaultUtils.set(true, forKey: .hasOpenedAlbum)
        UserDefaultUtils.set(true, forKey: .pendingCloudDataWipe)

        XCTAssertNil(groupDefaults.object(forKey: UserDefaultKey.hasOpenedAlbum.rawValue),
                     "an album-grid refresh fired by the erase's own deletions must not write settings back")
        XCTAssertTrue(UserDefaultUtils.bool(forKey: .pendingCloudDataWipe))
    }

    func testRemoveAllWritesTheTombstoneLast() {
        groupDefaults.set("x", forKey: "someSetting")

        UserDefaultUtils.removeAll(setTombstone: true)

        XCTAssertNil(groupDefaults.object(forKey: "someSetting"))
        XCTAssertTrue(groupDefaults.bool(forKey: UserDefaultKey.pendingDefaultsWipe.rawValue))
    }
}
