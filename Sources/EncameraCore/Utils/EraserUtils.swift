//
//  EraserUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation

public enum ErasureScope {
    case appData
    case allData

    /// How far this scope's keychain sweep reaches.
    ///
    /// `.allData` is ACCOUNT-WIDE, and that is the point of it. The screen promises
    /// "ALL your stored keys 🔑 / Your password 🔐 / MEDIA YOU HAVE STORED LOCALLY OR
    /// ON iCLOUD", and `deleteAllCloudData()` already removes the CloudKit zone for
    /// every device on the Apple ID. Keeping the keychain device-local made the two
    /// halves contradict each other: the user's media was destroyed everywhere while
    /// the key and passcode that opened it survived everywhere — and with
    /// Multi-Device Mode on, every item is synchronizable, so a device-local sweep
    /// matched nothing at all.
    ///
    /// ENC-82 introduced the device-local default for the returning-user
    /// delete-my-iCloud-data path (ENC-75/ENC-94), where it is correct — that user
    /// still owns another device and must not have its key tombstoned. But that path
    /// never routed through here: `DestructiveOnboardingCoordinator` tombstones
    /// CloudKit records directly and issues no keychain deletion of its own. The
    /// default was protecting a caller that does not exist, at the cost of making
    /// this screen lie.
    ///
    /// `.appData` stays device-local. It is the forgot-passcode / start-over reset,
    /// which deliberately KEEPS the encrypted originals and the CloudKit zone, so
    /// tombstoning the account's keys would strand exactly the data it just promised
    /// to leave alone.
    public var keyDeletionScope: KeyDeletionScope {
        switch self {
        case .appData:
            return .deviceLocal
        case .allData:
            return .accountWide
        }
    }

    public var screenName: String {
        switch self {
        case .appData:
            return "app_data"
        case .allData:
            return "all_data"
        }
    }
}

/// The CloudKit teardown EraserUtils needs, expressed as a seam so tests can
/// verify "Erase All Data" without touching a live iCloud account.
public protocol CloudDataErasing {
    func deleteAllCloudData() async throws
    /// Whether the user could actually have CloudKit data — this device provisioned
    /// the zone, or an iCloud account is currently signed in. Gates the "iCloud data
    /// may remain" warning so a purely local, signed-out user never sees an
    /// unactionable false positive after a failed (irrelevant) zone delete.
    func mayHaveCloudKitData() async -> Bool
}

extension CloudKitContainer: CloudDataErasing {
    public func mayHaveCloudKitData() async -> Bool {
        if hasEverProvisionedZone { return true }
        return await isCloudKitAvailable()
    }
}

/// The local wipe steps, expressed as a seam so tests can verify the erase
/// sequence — each step independent, all steps running even when the cloud
/// delete fails — without wiping the test process's real defaults, keychain,
/// and filesystem.
public protocol LocalDataErasing {
    /// Halts in-flight CloudKit migrations (no further checkpoints or CloudKit
    /// ops) and removes the on-disk migration checkpoints.
    func eraseMigrationState() async
    /// Active backend cleanup (also clears that backend's in-memory caches).
    func eraseActiveBackendMedia() async
    /// Global sweep across every storage type, independent of the active album.
    func eraseAllLocalMediaFiles()
    /// Per-album encrypted media indexes.
    func eraseMediaIndexes()
    /// Local CloudKit blob cache (encrypted, evictable copies).
    func eraseBlobCache() async
    /// Decrypted preview thumbnails.
    func eraseThumbnails()
    /// Temp directories that can hold decrypted cleartext.
    func eraseTempDirectories()
    /// The App Group container's import directory, plus any pending-import state.
    ///
    /// This one holds CLEARTEXT media handed over by the Share Extension, and no
    /// erase step reached it before: `eraseAllLocalMediaFiles()` walks the storage
    /// models (Documents, the ubiquity container, Caches) and the App Group
    /// container is none of them. A user who shared a photo into Encamera and then
    /// erased everything was leaving the decrypted original on disk.
    func eraseSharedContainerImports() async
    func eraseKeychain()
    func eraseUserDefaults()
    /// Durably records that a cloud wipe is still owed (written AFTER the defaults
    /// wipe so it survives it); the app retries on launch until it succeeds.
    func recordPendingCloudWipe()
}

/// Production implementation of the local wipe steps.
struct DefaultLocalDataEraser: LocalDataErasing, DebugPrintable {

    let keyManager: KeyManager
    let fileAccess: FileAccess
    /// How far the keychain wipe reaches. Defaults to `.deviceLocal`: "erase this
    /// device" must never tombstone the account's keys on devices the user still
    /// owns. `.accountWide` is a separate, explicitly-labelled action (ENC-72).
    let keyDeletionScope: KeyDeletionScope

    func eraseMigrationState() async {
        await MainActor.run { CloudKitMigrationManager.requestAbortAll() }
        do {
            try MigrationPlanStore.clearAllPlans()
        } catch {
            printDebug("EraserUtils: could not clear migration plans: \(error)")
        }
    }

    func eraseActiveBackendMedia() async {
        do {
            try await fileAccess.deleteAllMedia()
        } catch {
            printDebug("EraserUtils: could not delete active backend media: \(error)")
        }
    }

    /// Deletes every local album tree across all storage types, regardless of which
    /// album's backend is currently configured. Mirrors `DiskFileAccess.deleteAllMedia`.
    func eraseAllLocalMediaFiles() {
        for type in StorageType.allCases {
            guard case .available = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: type) else {
                continue
            }
            do {
                try type.modelForType.deleteAllFiles()
            } catch {
                printDebug("EraserUtils: could not delete all files for \(type): \(error)")
            }
        }
    }

    func eraseMediaIndexes() {
        do {
            try MediaIndexStore.clearAllIndexes()
        } catch {
            printDebug("EraserUtils: could not clear media indexes: \(error)")
        }
    }

    func eraseBlobCache() async {
        do {
            try await CloudKitBlobCache.shared.clearAll()
        } catch {
            printDebug("EraserUtils: could not clear blob cache: \(error)")
        }
        // Captures that never made it to CloudKit live outside the cache, in the
        // durable holding folder. An erase that skipped them would leave the
        // user's most recent photos on the device after they asked for
        // everything to be wiped.
        do {
            try await CloudKitUploadQueue.shared.clearAll()
        } catch {
            printDebug("EraserUtils: could not clear the pending upload queue: \(error)")
        }
    }

    func eraseThumbnails() {
        do {
            try DiskFileAccess.deleteThumbnailDirectory()
        } catch {
            printDebug("EraserUtils: could not delete thumbnail directory: \(error)")
        }
    }

    func eraseTempDirectories() {
        for url in [URL.tempMediaDirectory, URL.tempRecordingDirectory, URL.tempExportDirectory] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                printDebug("EraserUtils: could not remove temp directory \(url.lastPathComponent): \(error)")
            }
        }
    }

    func eraseSharedContainerImports() async {
        do {
            try await PendingImportManager.shared.cancelPendingImports()
        } catch {
            printDebug("EraserUtils: could not cancel pending imports: \(error)")
        }
        // Belt and braces: `cancelPendingImports` is about the import *queue*, and a
        // file left behind by a Share Extension run that never reached the queue
        // would survive it. This clears the directory itself, non-media included.
        do {
            try AppGroupFileAccess.shared.clearImportDirectory()
        } catch {
            printDebug("EraserUtils: could not clear the App Group import directory: \(error)")
        }
    }

    func eraseKeychain() {
        keyManager.clearKeychainData(scope: keyDeletionScope)
    }

    func eraseUserDefaults() {
        UserDefaultUtils.removeAll()
        // `UserDefaultUtils` owns the app-group suite and the iCloud key-value
        // store, which is where everything it writes lives — but the app and its
        // extensions also write to `UserDefaults.standard` (RevenueCat's cache,
        // feature-toggle scratch, anything using a bare `UserDefaults()`), and that
        // domain survived every erase. "App settings 🎛" has to mean all of them.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }

    func recordPendingCloudWipe() {
        UserDefaultUtils.set(true, forKey: .pendingCloudDataWipe)
    }
}

/// Outcome of an erase. `cloudKitDeletionFailed` is true only when an `.allData`
/// wipe could not remove the user's CloudKit data (offline, transient error) AND
/// the user could actually have data there — the local wipe still completed, so
/// the caller should warn that iCloud data may remain rather than report a clean
/// reset. A pending-wipe marker is persisted in that case and retried on launch.
public struct ErasureResult {
    public let cloudKitDeletionFailed: Bool

    public init(cloudKitDeletionFailed: Bool) {
        self.cloudKitDeletionFailed = cloudKitDeletionFailed
    }
}

public struct EraserUtils {

    public var keyManager: KeyManager
    public var fileAccess: FileAccess
    public var erasureScope: ErasureScope
    /// How far the keychain wipe reaches. Derived from `erasureScope` unless a
    /// caller overrides it — see `ErasureScope.keyDeletionScope` for why `.allData`
    /// resolves to `.accountWide`.
    public var keyDeletionScope: KeyDeletionScope
    private let cloudKitEraser: CloudDataErasing
    private let localEraser: LocalDataErasing

    /// - Parameter keyDeletionScope: pass only to deviate from the scope's own
    ///   answer. `nil` — the default — takes `erasureScope.keyDeletionScope`, so a
    ///   caller cannot get the wrong blast radius by forgetting the argument.
    public init(keyManager: KeyManager,
                fileAccess: FileAccess,
                erasureScope: ErasureScope,
                keyDeletionScope: KeyDeletionScope? = nil,
                cloudKitEraser: CloudDataErasing = CloudKitContainer.shared,
                localEraser: LocalDataErasing? = nil) {
        let resolvedKeyScope = keyDeletionScope ?? erasureScope.keyDeletionScope
        self.keyManager = keyManager
        self.fileAccess = fileAccess
        self.erasureScope = erasureScope
        self.keyDeletionScope = resolvedKeyScope
        self.cloudKitEraser = cloudKitEraser
        self.localEraser = localEraser ?? DefaultLocalDataEraser(keyManager: keyManager, fileAccess: fileAccess, keyDeletionScope: resolvedKeyScope)
    }

    @discardableResult
    public func erase() async throws -> ErasureResult {
        switch erasureScope {
        case .appData:
            await eraseAppData()
            return ErasureResult(cloudKitDeletionFailed: false)
        case .allData:
            return await eraseAllData()
        }
    }

    /// Full reset: removes everything the user generated — their CloudKit data
    /// (across all devices), every local album regardless of which one is active,
    /// the media index, on-disk caches/thumbnails, cleartext temp dirs, migration
    /// checkpoints, the encryption keys, and all UserDefaults / iCloud key-value
    /// state. Each step is independent so a single failure never skips the rest.
    /// In-flight migrations are halted FIRST so nothing keeps writing checkpoints
    /// or issuing CloudKit operations after the zone delete; the keychain wipe
    /// runs last (deleting the keys orphans nothing once the cloud records are gone).
    private func eraseAllData() async -> ErasureResult {
        await localEraser.eraseMigrationState()

        var cloudKitDeletionFailed = false
        var cloudWipeOwed = false
        do {
            try await cloudKitEraser.deleteAllCloudData()
        } catch {
            print("EraserUtils: CloudKit deletion failed: \(error)")
            // Warn only when there could actually be CloudKit data: a signed-out
            // purely-local user would otherwise get an unactionable "iCloud data
            // may remain" alert over data that never existed. The heuristic gates
            // ONLY the alert — `hasEverProvisionedZone` lives in defaults that an
            // `.appData` reset or reinstall destroys, so a false negative here is
            // entirely possible with a vault full of photos still in the private
            // database. The durable retry marker is persisted on every non-benign
            // failure: the launch retry is free and self-clearing (a missing zone
            // is treated as benign success, which clears it).
            cloudKitDeletionFailed = await cloudKitEraser.mayHaveCloudKitData()
            cloudWipeOwed = true
        }

        await localEraser.eraseActiveBackendMedia()
        localEraser.eraseAllLocalMediaFiles()
        localEraser.eraseMediaIndexes()
        await localEraser.eraseBlobCache()
        localEraser.eraseThumbnails()
        localEraser.eraseTempDirectories()
        await localEraser.eraseSharedContainerImports()

        localEraser.eraseKeychain()
        localEraser.eraseUserDefaults()

        if cloudWipeOwed {
            // After the defaults wipe, so the marker survives it. The alert the
            // caller shows is transient (the app exits right after); this durable
            // marker is what actually gets the zone deleted, on a later launch.
            localEraser.recordPendingCloudWipe()
        }

        return ErasureResult(cloudKitDeletionFailed: cloudKitDeletionFailed)
    }

    /// Forgot-passcode / start-over reset: destroys the keys and app state, plus
    /// every DERIVED cache of the now-undecryptable data (decrypted thumbnails,
    /// media indexes, blob cache, cleartext temp files, migration checkpoints) so
    /// no readable artifacts survive into the new install.
    ///
    /// Intentionally KEEPS the encrypted originals and the CloudKit zone: the same
    /// album keys may still exist on the user's other devices (iCloud Keychain),
    /// so the remote records — and local ciphertext re-paired with a recovered
    /// key — can remain usable there. Destroying them is exclusively the
    /// `.allData` scope's contract.
    private func eraseAppData() async {
        await localEraser.eraseMigrationState()
        localEraser.eraseMediaIndexes()
        await localEraser.eraseBlobCache()
        localEraser.eraseThumbnails()
        localEraser.eraseTempDirectories()
        // Cleartext, and therefore a derived readable artifact like the thumbnails
        // and temp files above — not one of the encrypted originals this scope
        // deliberately preserves.
        await localEraser.eraseSharedContainerImports()
        localEraser.eraseKeychain()
        localEraser.eraseUserDefaults()
    }
}
