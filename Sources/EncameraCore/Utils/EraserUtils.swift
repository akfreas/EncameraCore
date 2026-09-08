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
    /// Removes every subscription in the private database; a zone delete does
    /// not take the zone subscription with it.
    func deleteAllSubscriptions() async throws
    /// Owned zone names still present on the server after `deleteAllCloudData`.
    func remainingZoneNames() async throws -> [String]
    func remainingSubscriptionIDs() async throws -> [String]
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
    /// Cancels all in-flight CloudKit syncs, uploads, and blob downloads so the
    /// zone delete is the only CloudKit operation in flight. Must run before
    /// `deleteAllCloudData`.
    func shutdownCloudKitSync() async
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
    /// Everything left in the app's own container trees, whatever put it there.
    ///
    /// Every step above names a surface someone remembered. This one names none of
    /// them, which is the point: a feature that writes somewhere new and does not
    /// register itself here leaves user data behind an erase, silently and
    /// indefinitely. The CloudKit asset snapshots were exactly that — one copy of
    /// every chunk ever fetched, in a directory no erase step and no verifier knew
    /// about. `.allData` only: the app-data scope keeps the encrypted originals on
    /// purpose.
    ///
    /// MUST only run on a path that then terminates the app. The sweep includes
    /// `Library/Caches/CloudKit`, and removing that under a running `cloudd` does
    /// not merely discard cached assets — the next fetch fails with
    /// `chunkNotFound` for a record that exists (measured on device, 26 Aug 2026).
    /// `PromptToErase` calls `exit(0)` immediately afterwards, so CloudKit rebuilds
    /// on the next launch; a caller that erased and carried on would break every
    /// CloudKit read for the rest of the session.
    func eraseResidualContainerFiles()
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

    func shutdownCloudKitSync() async {
        await CloudKitUploader.shared.shutdown()
        await CloudKitCoordinatorRegistry.shared.shutdownAll()
        printDebug("EraserUtils: CloudKit sync infrastructure shut down")
    }

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
        // deleteAllFiles() empties each storage model's albums directory but
        // leaves the directory itself. For iCloud Drive the empty "albums"
        // directory triggers ExistingDataProbe's legacy sweep — remove the
        // whole Documents tree so the ubiquity container is truly clean.
        if let ubiquityRoot = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let documents = ubiquityRoot.appendingPathComponent("Documents")
            let albums = documents.appendingPathComponent("albums")
            for target in [albums, documents] {
                do {
                    try FileManager.default.removeItem(at: target)
                    printDebug("EraserUtils: removed ubiquity \(target.lastPathComponent)")
                } catch {
                    printDebug("EraserUtils: could not remove ubiquity \(target.lastPathComponent): \(error)")
                }
            }
        } else {
            printDebug("EraserUtils: ubiquity container unavailable — cannot clean iCloud Drive")
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
        // The CloudKit asset snapshot directory belongs here with the rest: it
        // holds a copy of every chunk this device has fetched, which is media
        // bytes, and an erase that leaves them behind has not erased the media.
        for url in [URL.tempMediaDirectory,
                    URL.tempRecordingDirectory,
                    URL.tempExportDirectory,
                    CKDatabaseAdapter.assetSnapshotDirectory] {
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

    func eraseResidualContainerFiles() {
        eraseResidualContainerFiles(roots: EraserUtils.containerRoots)
    }

    /// Root-injecting form, so a test can prove the walk against a tree it owns
    /// rather than against the container it is running inside.
    func eraseResidualContainerFiles(roots: [URL]) {
        for root in roots {
            removeContents(of: root)
        }
    }

    /// Removes every child of `directory` except the preserved names.
    ///
    /// Directories are emptied and then removed, rather than removed outright.
    /// Deleting a parent wholesale is faster but takes anything preserved inside
    /// it along — `Preferences` lives under `Library`, so a bulk delete of
    /// `Library` destroys exactly what the skip list is there to protect. The
    /// final removal is best-effort for the same reason: a directory that still
    /// holds preserved content should stay, and a system-owned one the app cannot
    /// delete has still had every file it owns taken out of it.
    private func removeContents(of directory: URL) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: []) else {
            return
        }
        for child in children where !EraserUtils.preservedNames.contains(child.lastPathComponent) {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                removeContents(of: child)
                // Only when it is actually empty: `removeItem` deletes a directory
                // and everything under it, so calling it on a parent that still
                // holds preserved content would delete that content too.
                if (try? fileManager.contentsOfDirectory(atPath: child.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: child)
                }
            } else {
                do {
                    try fileManager.removeItem(at: child)
                } catch {
                    printDebug("EraserUtils: could not remove \(child.lastPathComponent): \(error)")
                }
            }
        }
    }

    func eraseKeychain() {
        keyManager.clearKeychainData(scope: keyDeletionScope)
    }

    func eraseUserDefaults() {
        UserDefaultUtils.removeAll(setTombstone: true)
        // `UserDefaultUtils` owns the app-group suite and the iCloud key-value
        // store, which is where everything it writes lives — but the app and its
        // extensions also write to `UserDefaults.standard` (RevenueCat's cache,
        // feature-toggle scratch, anything using a bare `UserDefaults()`), and that
        // domain survived every erase. "App settings 🎛" has to mean all of them.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaultUtils.flushPendingWrites()
    }

    func recordPendingCloudWipe() {
        UserDefaultUtils.set(true, forKey: .pendingCloudDataWipe)
        UserDefaultUtils.flushPendingWrites()
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

    /// Every directory tree this app can write to.
    ///
    /// The home container covers `Documents`, `Library` and `tmp`; the App Group
    /// container is separate and is where the Share Extension hands media over;
    /// the ubiquity container holds legacy iCloud Drive albums.
    public static var containerRoots: [URL] {
        var roots = [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)]
        if let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: UserDefaultUtils.appGroup) {
            roots.append(group)
        }
        if let ubiquity = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            roots.append(ubiquity)
        }
        return roots
    }

    /// Names left untouched inside a container root.
    ///
    /// `Preferences` belongs to `cfprefsd`, which owns the plists and rewrites
    /// them from memory — deleting the files underneath it produces the
    /// "Couldn't read values in CFPrefsPlistSource" breakage rather than a clean
    /// wipe. `eraseUserDefaults()` is how those are cleared. `SyncedPreferences`
    /// is the same arrangement for the iCloud key-value store daemon. The other
    /// two are owned by the container manager and cannot be removed by the app
    /// at all.
    public static let preservedNames: Set<String> = [
        "Preferences",
        "SyncedPreferences",
        "SystemData",
        ".com.apple.mobile_container_manager.metadata.plist"
    ]


    public var keyManager: KeyManager
    public var fileAccess: FileAccess
    public var erasureScope: ErasureScope
    /// How far the keychain wipe reaches. Derived from `erasureScope` unless a
    /// caller overrides it — see `ErasureScope.keyDeletionScope` for why `.allData`
    /// resolves to `.accountWide`.
    public var keyDeletionScope: KeyDeletionScope
    private let cloudKitEraser: CloudDataErasing
    private let localEraser: LocalDataErasing
    private let localVerifier: LocalDataVerifying
    /// Steps owned by the app target, run after the media sweep and before the
    /// residual sweep, keychain and defaults wipes so nothing they write survives.
    private let appLayerSteps: [ErasureStep]

    /// - Parameter keyDeletionScope: pass only to deviate from the scope's own
    ///   answer. `nil` — the default — takes `erasureScope.keyDeletionScope`, so a
    ///   caller cannot get the wrong blast radius by forgetting the argument.
    public init(keyManager: KeyManager,
                fileAccess: FileAccess,
                erasureScope: ErasureScope,
                keyDeletionScope: KeyDeletionScope? = nil,
                cloudKitEraser: CloudDataErasing = CloudKitContainer.shared,
                localEraser: LocalDataErasing? = nil,
                localVerifier: LocalDataVerifying? = nil,
                appLayerSteps: [ErasureStep] = []) {
        let resolvedKeyScope = keyDeletionScope ?? erasureScope.keyDeletionScope
        self.keyManager = keyManager
        self.fileAccess = fileAccess
        self.erasureScope = erasureScope
        self.keyDeletionScope = resolvedKeyScope
        self.cloudKitEraser = cloudKitEraser
        self.localEraser = localEraser ?? DefaultLocalDataEraser(keyManager: keyManager, fileAccess: fileAccess, keyDeletionScope: resolvedKeyScope)
        self.localVerifier = localVerifier ?? DefaultLocalDataVerifier(keyManager: keyManager, fileAccess: fileAccess)
        self.appLayerSteps = appLayerSteps
    }

    /// Every step an `.allData` run reports, in run order: the core catalog with
    /// the app-layer steps inserted into their section. Rendered by the progress
    /// screen before the run starts.
    public var stepDescriptors: [ErasureStepDescriptor] {
        let catalog = ErasureStepDescriptor.allDataCatalog
        let appSectionIndex = ErasureStepSection.allCases.firstIndex(of: .app)!
        let before = catalog.filter { ErasureStepSection.allCases.firstIndex(of: $0.section)! < appSectionIndex }
        let after = catalog.filter { ErasureStepSection.allCases.firstIndex(of: $0.section)! > appSectionIndex }
        return before + appLayerSteps.map(\.descriptor) + after
    }

    @discardableResult
    public func erase() async throws -> ErasureResult {
        switch erasureScope {
        case .appData:
            await eraseAppData()
            return ErasureResult(cloudKitDeletionFailed: false)
        case .allData:
            let report = await eraseAllData(progress: { _ in })
            return ErasureResult(cloudKitDeletionFailed: report.cloudKitDeletionFailed)
        }
    }

    /// Full reset: removes everything the user generated — their CloudKit data
    /// (across all devices), every local album regardless of which one is active,
    /// the media index, on-disk caches/thumbnails, cleartext temp dirs, migration
    /// checkpoints, the encryption keys, and all UserDefaults / iCloud key-value
    /// state.
    ///
    /// Runs `stepDescriptors` in order and reports each through `progress` twice:
    /// `.running`, then the terminal outcome its verification decided. A failure
    /// never stops the run. In-flight migrations are halted FIRST so nothing keeps
    /// writing checkpoints or issuing CloudKit operations after the zone delete;
    /// the CloudKit checks run before the residual sweep, which removes
    /// `Library/Caches/CloudKit` and breaks every later CloudKit read; the
    /// keychain wipe runs after the media so deleting the keys orphans nothing.
    public func eraseAllData(progress: @escaping @Sendable (ErasureStepReport) -> Void) async -> ErasureReport {
        var steps: [ErasureStepReport] = []
        var cloudKitDeletionFailed = false
        var cloudWipeOwed = false

        func record(_ report: ErasureStepReport) {
            steps.append(report)
            progress(report)
        }

        /// Erase, then verify whatever the erase did. The verdict decides the
        /// outcome; an erase error is kept as evidence only.
        func perform(_ id: String,
                     erase: () async throws -> Void,
                     verify: () async -> ErasureVerdict) async {
            progress(.running(id))
            var eraseError: Error?
            do {
                try await erase()
            } catch {
                print("EraserUtils: \(id) failed: \(error)")
                eraseError = error
            }
            let verdict = await verify()
            record(.terminal(id, verdict: verdict, eraseError: eraseError))
        }

        await perform("migration.state",
                      erase: { await localEraser.eraseMigrationState() },
                      verify: { await localVerifier.verifyMigrationState() })
        await perform("sync.shutdown",
                      erase: { await localEraser.shutdownCloudKitSync() },
                      verify: { await localVerifier.verifyCloudKitSyncShutdown() })

        // Cloud. A failure here is the one the launch-time retry exists for, so
        // it is recorded durably below whatever the outcome shown to the user.
        progress(.running("cloud.zones"))
        do {
            try await cloudKitEraser.deleteAllCloudData()
            record(await cloudVerdict("cloud.zones", label: "iCloud zones") {
                try await cloudKitEraser.remainingZoneNames()
            })
        } catch {
            print("EraserUtils: CloudKit deletion failed: \(error)")
            cloudWipeOwed = true
            // Warn only when there could actually be CloudKit data: a signed-out
            // purely-local user would otherwise get an unactionable "iCloud data
            // may remain" report over data that never existed. The heuristic gates
            // ONLY the report — `hasEverProvisionedZone` lives in defaults that a
            // reinstall destroys, so a false negative here is entirely possible
            // with a vault full of photos still in the private database. The
            // durable retry marker is persisted on every non-benign failure.
            if await cloudKitEraser.mayHaveCloudKitData() {
                cloudKitDeletionFailed = true
                // The server may have committed the delete even though the client
                // saw an error; only a re-read can say.
                record(await cloudVerdict("cloud.zones", label: "iCloud zones", eraseError: error) {
                    try await cloudKitEraser.remainingZoneNames()
                })
            } else {
                record(.skipped("cloud.zones", "No iCloud account on this device"))
            }
        }

        progress(.running("cloud.subscriptions"))
        do {
            try await cloudKitEraser.deleteAllSubscriptions()
            record(await cloudVerdict("cloud.subscriptions", label: "iCloud subscriptions") {
                try await cloudKitEraser.remainingSubscriptionIDs()
            })
        } catch {
            print("EraserUtils: CloudKit subscription deletion failed: \(error)")
            if await cloudKitEraser.mayHaveCloudKitData() {
                cloudWipeOwed = true
                record(.terminal("cloud.subscriptions",
                                 verdict: .fail("Could not reach iCloud", hint: .cloudUnreachable),
                                 eraseError: error))
            } else {
                record(.skipped("cloud.subscriptions", "No iCloud account on this device"))
            }
        }

        await perform("media.activeBackend",
                      erase: { await localEraser.eraseActiveBackendMedia() },
                      verify: { await localVerifier.verifyActiveBackendMedia() })
        await perform("media.localAlbums",
                      erase: { localEraser.eraseAllLocalMediaFiles() },
                      verify: { localVerifier.verifyLocalMediaFiles() })
        await perform("media.indexes",
                      erase: { localEraser.eraseMediaIndexes() },
                      verify: { localVerifier.verifyMediaIndexes() })
        await perform("media.blobCache",
                      erase: { await localEraser.eraseBlobCache() },
                      verify: { localVerifier.verifyBlobCache() })
        await perform("media.thumbnails",
                      erase: { localEraser.eraseThumbnails() },
                      verify: { localVerifier.verifyThumbnails() })
        await perform("media.temp",
                      erase: { localEraser.eraseTempDirectories() },
                      verify: { localVerifier.verifyTempDirectories() })
        await perform("media.sharedImports",
                      erase: { await localEraser.eraseSharedContainerImports() },
                      verify: { localVerifier.verifySharedContainerImports() })

        for step in appLayerSteps {
            await perform(step.descriptor.id, erase: step.erase, verify: step.verify)
        }

        // Deliberately indiscriminate: whatever the named steps above missed is
        // still user data.
        await perform("sweep.residual",
                      erase: { localEraser.eraseResidualContainerFiles() },
                      verify: { localVerifier.verifyResidualContainerFiles() })
        await perform("keys.keychain",
                      erase: { localEraser.eraseKeychain() },
                      verify: { localVerifier.verifyKeychain() })
        await perform("settings.defaults",
                      erase: {
                          localEraser.eraseUserDefaults()
                          if cloudWipeOwed {
                              // After the defaults wipe, so the marker survives it.
                              localEraser.recordPendingCloudWipe()
                          }
                      },
                      verify: { localVerifier.verifyUserDefaults() })

        await perform("final.verify",
                      erase: {},
                      verify: { await localVerifier.verifyDeviceClean() })

        let report = ErasureReport(descriptors: stepDescriptors,
                                   steps: steps,
                                   cloudKitDeletionFailed: cloudKitDeletionFailed)
        print(report.fullText)
        return report
    }

    /// Re-reads a cloud surface. A read that itself fails means iCloud is
    /// unreachable, which is a failure with a retry hint rather than a pass.
    private func cloudVerdict(_ id: String,
                              label: String,
                              eraseError: Error? = nil,
                              remaining: () async throws -> [String]) async -> ErasureStepReport {
        do {
            let names = try await remaining()
            return .terminal(id,
                             verdict: .residue(label, names: names, hint: .cloudUnreachable),
                             eraseError: eraseError)
        } catch {
            return .terminal(id,
                             verdict: .fail("Could not reach iCloud", detail: "\(error)", hint: .cloudUnreachable),
                             eraseError: eraseError)
        }
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
