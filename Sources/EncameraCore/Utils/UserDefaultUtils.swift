//
//  UserDefaultUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation
import Combine

public struct UserDefaultUtils: DebugPrintable {

    #if DEBUG
    public static var appGroup = "group.me.freas.encamera.debug"
    #else
    public static var appGroup = "group.me.freas.encamera"
    #endif
    
    // MARK: - Constants
    
    private static let iCloudMigrationKey = "DidMigrateToiCloud_v1"
    
    // MARK: - Storage Backends
    
    /// Local storage using UserDefaults with App Group support
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? UserDefaults.standard
    }
    
    /// iCloud storage using NSUbiquitousKeyValueStore
    private static var cloudStore: NSUbiquitousKeyValueStore {
        NSUbiquitousKeyValueStore.default
    }
    
    // MARK: - Notification Observers
    
    private static var iCloudObserver: NSObjectProtocol?
    private static var defaultsPublisher: AnyPublisher<(UserDefaultKey, Any?), Never> {
        defaultsSubject.eraseToAnyPublisher()
    }
    
    private static var defaultsSubject: PassthroughSubject = PassthroughSubject<(UserDefaultKey, Any?), Never>()

    private static var iCloudKeysChangedSubject = PassthroughSubject<[String], Never>()

    /// Emits the raw key strings that changed in NSUbiquitousKeyValueStore due
    /// to an external change (another device wrote them). Compare against
    /// `UserDefaultKey.rawValue` — e.g. "onboardingState" — to react to a
    /// specific key arriving.
    public static var iCloudKeysChangedPublisher: AnyPublisher<[String], Never> {
        iCloudKeysChangedSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    public init() {}
    
    /// Call this method at app startup to register for iCloud sync notifications
    public static func setupiCloudSync() {
        // Register for iCloud change notifications
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { notification in
            handleiCloudChange(notification)
        }
        
        // Trigger initial synchronization with iCloud
        cloudStore.synchronize()
        
        printDebug("[UserDefaultUtils] iCloud sync initialized")
    }
    
    public static func tearDowniCloudSync() {
        if let observer = iCloudObserver {
            NotificationCenter.default.removeObserver(observer)
            iCloudObserver = nil
        }
    }
    
    // MARK: - iCloud Change Handling
    
    private static func handleiCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        
        // Check the reason for change
        if let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
            switch changeReason {
            case NSUbiquitousKeyValueStoreServerChange,
                 NSUbiquitousKeyValueStoreInitialSyncChange:
                // Valid sync changes - proceed with update
                break
            case NSUbiquitousKeyValueStoreQuotaViolationChange:
                printDebug("[UserDefaultUtils] WARNING: iCloud quota violation")
                return
            case NSUbiquitousKeyValueStoreAccountChange:
                printDebug("[UserDefaultUtils] iCloud account changed - resyncing")
            default:
                break
            }
        }
        
        // Get the keys that changed
        if let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            for keyString in changedKeys {
                // Try to match the changed key to our UserDefaultKey enum
                // We'll update the local defaults with iCloud values
                if let value = cloudStore.object(forKey: keyString) {
                    defaults.set(value, forKey: keyString)
                    printDebug("[UserDefaultUtils] Synced from iCloud: \(keyString)")

                    // Notify observers about the change
                    // Note: We can't reconstruct the full UserDefaultKey enum from string easily
                    // So we'll send a generic notification
                    defaultsSubject.send((UserDefaultKey.savedSettings, value)) // Placeholder
                }
            }
            if !changedKeys.isEmpty {
                iCloudKeysChangedSubject.send(changedKeys)
            }
        }
    }
    
    // MARK: - Public API
    
    public static func increaseInteger(forKey key: UserDefaultKey) {
        var currentValue = value(forKey: key) as? Int ?? 0
        currentValue += 1
        set(currentValue, forKey: key)
    }

    public static func increaseInteger(forKey key: UserDefaultKey, by number: Int) {
        var currentValue = value(forKey: key) as? Int ?? 0
        currentValue += number
        set(currentValue, forKey: key)
    }

    public static func publisher(for observedKey: UserDefaultKey) -> AnyPublisher<Any?, Never> {
        return defaultsPublisher.filter { key, value in
            return observedKey == key
        }.map { key, value in
            return value
        }.share().eraseToAnyPublisher()
    }
    
    public static func integer(forKey key: UserDefaultKey) -> Int {
        return defaults.integer(forKey: key.rawValue)
    }

    public static func string(forKey key: UserDefaultKey) -> String? {
        return defaults.string(forKey: key.rawValue)
    }
    
    public static func set(_ value: Any?, forKey key: UserDefaultKey) {
        let keyString = key.rawValue
        
        // Always write to local storage
        defaults.set(value, forKey: keyString)
        
        // If this key should sync, also write to iCloud
        if key.shouldSyncToiCloud {
            if let value = value {
                cloudStore.set(value, forKey: keyString)
                cloudStore.synchronize() // Request immediate sync
                printDebug("[UserDefaultUtils] Set to iCloud: \(keyString)")
            } else {
                cloudStore.removeObject(forKey: keyString)
                cloudStore.synchronize()
                printDebug("[UserDefaultUtils] Removed from iCloud: \(keyString)")
            }
        }
        
        defaultsSubject.send((key, value))
    }
    
    public static func value(forKey key: UserDefaultKey) -> Any? {
        return defaults.value(forKey: key.rawValue)
    }
    public static func boolNullable(forKey key: UserDefaultKey) -> Bool? {
        if defaults.object(forKey: key.rawValue) == nil {
            return nil
        }
        return defaults.bool(forKey: key.rawValue)
    }
    public static func bool(forKey key: UserDefaultKey) -> Bool {
        return boolNullable(forKey: key) ?? false
    }
    
    public static func removeObject(forKey key: UserDefaultKey) {
        let keyString = key.rawValue
        
        defaults.removeObject(forKey: keyString)
        
        if key.shouldSyncToiCloud {
            cloudStore.removeObject(forKey: keyString)
            cloudStore.synchronize()
            printDebug("[UserDefaultUtils] Removed from iCloud: \(keyString)")
        }
        
        defaultsSubject.send((key, nil))
    }

    public static func dictionary(forKey key: UserDefaultKey) -> [String: Any]? {
        return defaults.dictionary(forKey: key.rawValue)
    }

    public static func data(forKey key: UserDefaultKey) -> Data? {
        return defaults.data(forKey: key.rawValue)
    }
    
    public static func removeAll() {
        defaults.dictionaryRepresentation().keys.forEach { key in
            defaults.removeObject(forKey: key)
        }
        
        // Also clear all iCloud keys
        if let cloudDict = cloudStore.dictionaryRepresentation as? [String: Any] {
            cloudDict.keys.forEach { key in
                cloudStore.removeObject(forKey: key)
            }
            cloudStore.synchronize()
        }
    }

    /// Keys still set in any domain this app writes to, excluding the ones the
    /// system owns. Used to verify an erase actually emptied them.
    ///
    /// Reads `persistentDomain(forName:)` rather than `dictionaryRepresentation()`:
    /// the latter composes the global domain in, so it reports `AppleLanguages` and
    /// every keyboard preference as though the app had written them. The persistent
    /// domain is what this app actually owns — but iOS still deposits a handful of
    /// managed entries there and re-creates some of them immediately after a wipe,
    /// so those prefixes are filtered out. A key surviving this filter is residue
    /// the erase was supposed to remove.
    public static func encameraOwnedKeysStillSet() -> [String] {
        var keys = Set<String>()

        if let groupDefaults = UserDefaults(suiteName: appGroup),
           let domain = groupDefaults.persistentDomain(forName: appGroup) {
            keys.formUnion(domain.keys)
        }
        if let bundleID = Bundle.main.bundleIdentifier,
           let domain = UserDefaults.standard.persistentDomain(forName: bundleID) {
            keys.formUnion(domain.keys)
        }
        keys.formUnion(cloudStore.dictionaryRepresentation.keys)

        return keys.filter { key in
            !systemOwnedDefaultsPrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// Entries iOS writes into an app's own persistent domain. Not ours to delete,
    /// and several reappear the instant the app touches a text field or a locale.
    static let systemOwnedDefaultsPrefixes = [
        "Apple", "NS", "com.apple.", "AK", "ACD", "PK", "INNext", "MSV", "WebKit",
        "AddingEmojiKeybord", "shouldShowRSVPDataDetectors"
    ]

    // MARK: - Migration

    public static func migrateUserDefaultsToAppGroups() {
        
        // User Defaults - Old
        let userDefaults = UserDefaults.standard
        
        // App Groups Default - New
        let groupDefaults = UserDefaults(suiteName: appGroup)
        
        // Key to track if we migrated
        let didMigrateToAppGroups = "DidMigrateToAppGroups"
        
        if let groupDefaults = groupDefaults {
            if !groupDefaults.bool(forKey: didMigrateToAppGroups) {
                for (key, value) in userDefaults.dictionaryRepresentation() {
                    groupDefaults.set(value, forKey: key)
                }
                groupDefaults.set(true, forKey: didMigrateToAppGroups)
                groupDefaults.synchronize()
                printDebug("Successfully migrated defaults to app groups")
            } else {
                printDebug("No need to migrate defaults to app groups")
            }
        } else {
            print("Unable to create NSUserDefaults with given app group")
        }
    }
    
    /// Checks if migration from UserDefaults to iCloud is needed
    public static func needsiCloudMigration() -> Bool {
        return !defaults.bool(forKey: iCloudMigrationKey)
    }
    
    /// The syncable keys whose raw values are known at compile time. Per-album
    /// settings now live in `SyncedDataStore` and are no longer individual KVS keys.
    private static let syncableKeys: [UserDefaultKey] = [
        .onboardingState, .savedSettings, .currentAlbumID, .showCurrentAlbumOnLaunch,
        .keyTutorialClosed, .hasOpenedAlbum, .defaultStorageLocation, .livePhotosActivated,
        .gridZoomLevel, .gridSortOption, .currentKey, .hasCompletedFirstLockout,
        .hasBeenShownHideAlbumTutorial
    ]

    /// Migrates eligible keys from local UserDefaults to NSUbiquitousKeyValueStore.
    /// Only keys whose `shouldSyncToiCloud == true` are migrated; per-album settings
    /// are handled by `SyncedDataStore` and are not part of this migration.
    public static func migrateToiCloudStorage() {
        guard needsiCloudMigration() else {
            printDebug("[UserDefaultUtils] iCloud migration already completed")
            return
        }

        printDebug("[UserDefaultUtils] Starting iCloud migration...")

        var migratedCount = 0

        for key in syncableKeys {
            let keyString = key.rawValue
            guard let value = defaults.value(forKey: keyString) else { continue }

            if cloudStore.object(forKey: keyString) == nil {
                cloudStore.set(value, forKey: keyString)
                migratedCount += 1
                printDebug("[UserDefaultUtils] Migrated to iCloud: \(keyString)")
            } else if let cloudValue = cloudStore.object(forKey: keyString) {
                defaults.set(cloudValue, forKey: keyString)
                printDebug("[UserDefaultUtils] Synced from iCloud: \(keyString)")
            }
        }

        cloudStore.synchronize()

        defaults.set(true, forKey: iCloudMigrationKey)
        defaults.synchronize()

        printDebug("[UserDefaultUtils] iCloud migration completed. Migrated \(migratedCount) keys.")
    }
    
}


public extension UserDefaultUtils {

    static func resetReviewMetric() {
        Self.set(0, forKey: .reviewRequestedMetric)
    }
}
