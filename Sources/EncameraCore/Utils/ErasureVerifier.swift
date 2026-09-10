//
//  ErasureVerifier.swift
//  EncameraCore
//
//  Checks, after an erase, that the things the screen promised to destroy are
//  actually gone — rather than assuming the steps that reported no error achieved
//  anything.
//
//  This exists because they demonstrably did not. "Erase All Data" swept the
//  keychain with `kSecAttrSynchronizable == false` while Multi-Device Mode made
//  every credential synchronizable, so the sweep matched nothing, threw nothing,
//  and the app exited reporting success with the user's passcode and key intact.
//  Every step in `EraserUtils` is independently `try?`-tolerant by design, so
//  "no error" has never been evidence of an empty device.
//

import Foundation

/// What survived an erase. Every field empty is the contract for `.allData`.
public struct ErasureResidue: Equatable, Sendable {
    /// `"<class>|<name>"` per surviving keychain item.
    public var keychainItems: [String] = []
    /// Paths that still exist and still hold something.
    public var files: [String] = []
    /// Defaults keys still set in the app-group suite, the standard domain, or the
    /// iCloud key-value store.
    public var defaultsKeys: [String] = []

    public init(keychainItems: [String] = [],
                files: [String] = [],
                defaultsKeys: [String] = []) {
        self.keychainItems = keychainItems
        self.files = files
        self.defaultsKeys = defaultsKeys
    }

    public var isClean: Bool {
        keychainItems.isEmpty && files.isEmpty && defaultsKeys.isEmpty
    }

    /// One line per surviving surface, for a log or an on-screen report. Names the
    /// residue rather than counting it: "3 items remain" is not actionable, and the
    /// item names here are keychain accounts and directory names, never contents.
    public var summary: String {
        var lines: [String] = []
        if !keychainItems.isEmpty {
            lines.append("keychain: \(keychainItems.joined(separator: ", "))")
        }
        if !files.isEmpty {
            lines.append("files: \(files.joined(separator: ", "))")
        }
        if !defaultsKeys.isEmpty {
            lines.append("defaults: \(defaultsKeys.joined(separator: ", "))")
        }
        return lines.isEmpty ? "clean" : lines.joined(separator: "\n")
    }
}

public protocol ErasureVerifying {
    /// Re-reads every surface the scope claims to have cleared.
    func verify(scope: ErasureScope) async -> ErasureResidue
}

/// Production verifier: queries the real keychain, filesystem and defaults.
///
/// Deliberately re-reads rather than trusting the eraser's own return values — a
/// verifier built from the same assumptions as the thing it verifies proves
/// nothing. It shares only the `KeyManager`, and only to issue a widest-match
/// keychain query.
public struct DefaultErasureVerifier: ErasureVerifying, DebugPrintable {

    private let keyManager: KeyManager

    public init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    public func verify(scope: ErasureScope) async -> ErasureResidue {
        var residue = ErasureResidue()

        // 1. Keychain. Only `.allData` promises to empty it; `.appData` deliberately
        // leaves the account's synced credentials alone, so checking them there
        // would report a designed outcome as a failure.
        if scope == .allData {
            residue.keychainItems = keyManager.residualKeychainItemNames()
                .filter { item in
                    !Self.thirdPartyKeychainAccounts.contains(where: { item.hasSuffix("|\($0)") })
                }
        }

        residue.files = survivingFiles(scope: scope)
        residue.defaultsKeys = survivingDefaultsKeys()

        printDebug("verify scope=\(scope.screenName) clean=\(residue.isClean) \(residue.summary)")
        return residue
    }

    // MARK: - Files

    /// Test seam: the file half of `verify`, without the keychain and defaults
    /// checks that need a provisioned account.
    public func survivingFilesForTesting(scope: ErasureScope, containerPathLimit: Int = 20) -> [String] {
        survivingFiles(scope: scope, containerPathLimit: containerPathLimit)
    }

    private func survivingFiles(scope: ErasureScope, containerPathLimit: Int = 20) -> [String] {
        var offenders: [String] = []

        // Cleartext first — these are the ones that matter most if they survive.
        var directories: [(label: String, url: URL?)] = [
            ("thumbnails", LocalStorageModel.thumbnailDirectory),
            ("tempMedia", URL.tempMediaDirectory),
            ("tempRecording", URL.tempRecordingDirectory),
            ("tempExport", URL.tempExportDirectory),
            ("sharedImports", AppGroupFileAccess.shared.importDirectoryURL)
        ]

        // The encrypted originals and the blob cache are `.allData`'s to destroy;
        // `.appData` keeps them on purpose.
        if scope == .allData {
            directories.append(("cloudKitBlobs", CloudKitBlobCache.defaultBaseDir))
            directories.append(("localAlbums", LocalStorageModel.albumsURL))
        }

        for entry in directories {
            guard let url = entry.url else { continue }
            if directoryHasContents(url) {
                offenders.append(entry.label)
            }
        }

        // The named surfaces above only catch what someone thought to list. For
        // the scope that claims EVERYTHING is gone, walk the containers instead
        // and report whatever is actually still there — that is the only check
        // that can see a directory nobody registered.
        if scope == .allData {
            offenders.append(contentsOf: survivingContainerPaths(limit: containerPathLimit))
        }
        return offenders
    }

    /// Paths still present under the app's container roots, as
    /// `<root>/<relative path>` strings, capped so a pathological case reports a
    /// usable summary rather than thousands of lines.
    ///
    /// Only files the app can actually delete count as residue. iOS protects
    /// certain paths (e.g. `privateStoreKit/receipt`) with EPERM — maintaining a
    /// whitelist for those is brittle, so we probe writability instead.
    private func survivingContainerPaths(limit: Int = 20) -> [String] {
        var offenders: [String] = []
        let fileManager = FileManager.default

        for root in EraserUtils.containerRoots {
            guard let walker = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                      options: []) else { continue }
            for case let url as URL in walker {
                let name = url.lastPathComponent
                if EraserUtils.preservedNames.contains(name) || Self.isRelaunchArtifact(name) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        walker.skipDescendants()
                    }
                    continue
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      name != ".DS_Store" else {
                    continue
                }
                if !fileManager.isDeletableFile(atPath: url.path) { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                offenders.append("container:\(root.lastPathComponent)/\(relative)")
                if offenders.count >= limit { return offenders }
            }
        }
        return offenders
    }

    /// A missing directory is clean. An empty one is clean too — the erase removes
    /// contents, and several of these are recreated the moment something asks for
    /// their URL, so "exists" is not evidence of residue.
    private func directoryHasContents(_ url: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return !contents.filter { $0 != ".DS_Store" }.isEmpty
    }

    // MARK: - Defaults

    /// Keys still set in any domain the app writes to. Filtered to Encamera's own
    /// keys: the app-group and standard domains also carry OS-managed entries
    /// (`AppleLanguages`, keyboard state) that no erase should remove and whose
    /// presence is not residue.
    private func survivingDefaultsKeys() -> [String] {
        UserDefaultUtils.encameraOwnedKeysStillSet()
            .filter { key in
                !Self.intentionalPostEraseKeys.contains(key)
                    && !Self.intentionalPostErasePrefixes.contains(where: { key.hasPrefix($0) })
            }
            .sorted()
    }

    /// Written deliberately AFTER the defaults wipe, or written by normal app
    /// initialization on a fresh launch. Finding these is the system working rather
    /// than residue — a fresh install writes every one of them on first launch.
    private static let intentionalPostEraseKeys: Set<String> = [
        UserDefaultKey.pendingCloudDataWipe.rawValue,
        UserDefaultKey.pendingDefaultsWipe.rawValue,
        UserDefaultKey.launchCountKey.rawValue,
        UserDefaultKey.lastVersionKey.rawValue,
        UserDefaultKey.showPushNotificationPrompt.rawValue,
        UserDefaultKey.reviewRequestedMetric.rawValue,
        UserDefaultKey.biometricsConfirmedOnThisDevice.rawValue,
        UserDefaultKey.biometricsSeedWindowClosed.rawValue,
        "completedAlbumsDirectoryMigrationV2",
        "DidMigrateToiCloud_v1",
        "CKStartupTime",
        "CKPerBootTasks",
        "CloudKitAccountInfoCache",
        "SKTransactionUpdatesLastChecked",
        "SK2PurchaseIntentUpdatesLastChecked",
        "com.encamera.skan.highestMilestone",
    ]

    /// Prefix-matched defaults written on fresh launch with a dynamic suffix
    /// (e.g. `cloudkit_zone_created_v1_<container>`, `featureToggle_*`).
    private static let intentionalPostErasePrefixes: [String] = [
        "cloudkit_zone_created_v1_",
        "featureToggle_",
    ]

    /// Directories that iOS or third-party SDKs recreate on every launch. Their
    /// presence in the container walk is not residue — the verify launch itself
    /// creates them.
    private static let relaunchArtifactDirs: Set<String> = [
        "caches",
        "saved application state",
        "httpstorages",
        "splashboard",
        "revenuecat",
        "encameraanalytics",
    ]

    /// RevenueCat has shipped its directory as `RevenueCat` and `revenuecat`, and
    /// now also keeps `<bundle id>.revenuecat.<purpose>` caches beside it; all of
    /// them reappear on the first purchases response of any launch.
    static func isRelaunchArtifact(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return relaunchArtifactDirs.contains(lowercased) || lowercased.contains(".revenuecat.")
    }

    /// Keychain accounts written by third-party SDKs during app initialization,
    /// not by Encamera. These appear on a fresh install too.
    static let thirdPartyKeychainAccounts: Set<String> = [
        "device_id",
        "visitor_id",
        "visitor_id_last_reported",
    ]
}

// MARK: - Per-step verification

/// One verification per erase step, each re-reading the surface the step just
/// cleared. `EraserUtils` decides a step's outcome from these, never from
/// whether the erase call threw.
public protocol LocalDataVerifying {
    func verifyCloudKitSyncShutdown() async -> ErasureVerdict
    func verifyMigrationState() async -> ErasureVerdict
    func verifyActiveBackendMedia() async -> ErasureVerdict
    func verifyLocalMediaFiles() -> ErasureVerdict
    func verifyICloudDriveMedia() -> ErasureVerdict
    func verifyMediaIndexes() -> ErasureVerdict
    func verifyBlobCache() -> ErasureVerdict
    func verifyThumbnails() -> ErasureVerdict
    func verifyTempDirectories() -> ErasureVerdict
    func verifySharedContainerImports() -> ErasureVerdict
    /// Strict container walk: after the residual sweep nothing but the preserved
    /// names and OS-owned state may remain.
    func verifyResidualContainerFiles() -> ErasureVerdict
    func verifyKeychain() -> ErasureVerdict
    func verifyUserDefaults() -> ErasureVerdict
    /// The whole-device sweep, run last: `DefaultErasureVerifier` plus the legacy
    /// iCloud Drive probe.
    func verifyDeviceClean() async -> ErasureVerdict
}

/// Production per-step verifier: queries the real keychain, filesystem, defaults
/// and in-process sync state.
public struct DefaultLocalDataVerifier: LocalDataVerifying, DebugPrintable {

    private let keyManager: KeyManager
    private let fileAccess: FileAccess

    public init(keyManager: KeyManager, fileAccess: FileAccess) {
        self.keyManager = keyManager
        self.fileAccess = fileAccess
    }

    public func verifyCloudKitSyncShutdown() async -> ErasureVerdict {
        let live = await CloudKitCoordinatorRegistry.shared.knownAlbumIDs()
        return .residue("live sync coordinators", names: live, hint: .retry)
    }

    public func verifyMigrationState() async -> ErasureVerdict {
        .residue("migration checkpoints", names: Self.files(under: MigrationPlanStore.directoryURL()), hint: .files)
    }

    public func verifyActiveBackendMedia() async -> ErasureVerdict {
        let media: [InteractableMedia<EncryptedMedia>] = await fileAccess.enumerateMedia()
        return .residue("media items in the current album", names: media.map(\.id), hint: .files)
    }

    public func verifyLocalMediaFiles() -> ErasureVerdict {
        let names = Self.files(under: LocalStorageModel.albumsURL).map { "local/\($0)" }
        return .residue("album files", names: names, hint: .files)
    }

    public func verifyICloudDriveMedia() -> ErasureVerdict {
        guard let ubiquity = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return .pass("no ubiquity container")
        }
        let names = Self.files(under: ubiquity.appendingPathComponent("Documents")).map { "iCloudDrive/\($0)" }
        return .residue("iCloud Drive files", names: names, hint: .files)
    }

    public func verifyMediaIndexes() -> ErasureVerdict {
        .residue("index files", names: Self.files(under: MediaIndexStore.indexDirectoryURL()), hint: .files)
    }

    public func verifyBlobCache() -> ErasureVerdict {
        var names = Self.files(under: CloudKitBlobCache.defaultBaseDir).map { "cache/\($0)" }
        names += Self.files(under: CloudKitUploadQueue.defaultBaseDir).map { "uploads/\($0)" }
        return .residue("cached or queued files", names: names, hint: .files)
    }

    public func verifyThumbnails() -> ErasureVerdict {
        .residue("thumbnails", names: Self.files(under: LocalStorageModel.thumbnailDirectory), hint: .files)
    }

    public func verifyTempDirectories() -> ErasureVerdict {
        var names: [String] = []
        for url in [URL.tempMediaDirectory,
                    URL.tempRecordingDirectory,
                    URL.tempExportDirectory,
                    CKDatabaseAdapter.assetSnapshotDirectory] {
            names += Self.files(under: url).map { "\(url.lastPathComponent)/\($0)" }
        }
        return .residue("temporary files", names: names, hint: .files)
    }

    public func verifySharedContainerImports() -> ErasureVerdict {
        guard let importDirectory = AppGroupFileAccess.shared.importDirectoryURL else {
            return .pass("no App Group container")
        }
        return .residue("shared import files", names: Self.files(under: importDirectory), hint: .files)
    }

    public func verifyResidualContainerFiles() -> ErasureVerdict {
        verifyResidualContainerFiles(roots: EraserUtils.containerRoots)
    }

    /// Root-injecting form so a test can prove the walk against a tree it owns.
    public func verifyResidualContainerFiles(roots: [URL]) -> ErasureVerdict {
        var names: [String] = []
        let fileManager = FileManager.default
        for root in roots {
            guard let walker = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                      options: []) else { continue }
            for case let url as URL in walker {
                let name = url.lastPathComponent
                if EraserUtils.preservedNames.contains(name) || Self.systemOwnedDirectories.contains(name) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        walker.skipDescendants()
                    }
                    continue
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      name != ".DS_Store",
                      fileManager.isDeletableFile(atPath: url.path) else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                names.append("\(root.lastPathComponent)/\(relative)")
            }
        }
        return .residue("container files", names: names, hint: .files)
    }

    public func verifyKeychain() -> ErasureVerdict {
        .residue("keychain items", names: keyManager.residualKeychainItemNames(), hint: .keychain)
    }

    /// Asks cfprefsd, not the plist files. The daemon is the only writer and
    /// rewrites a domain's file on its own cadence, around ten seconds after the
    /// last change, which no synchronize call shortens; a file read from inside
    /// the running app shows the pre-erase keys until then. The on-disk proof is
    /// the container pull the rig harness makes after the app has exited.
    public func verifyUserDefaults() -> ErasureVerdict {
        let keys = UserDefaultUtils.encameraOwnedKeysStillSet()
            .filter { !Self.frameworkOwnedDefaultsKeys.contains($0) && !Self.tombstoneKeys.contains($0) }
            .sorted()
        return .residue("settings keys", names: keys, hint: .settings)
    }

    /// Deliberately no CloudKit query here: a CloudKit read after the zone
    /// delete answers `zoneNotFound`, and the store reacts by rewriting the
    /// zone-created flag into the defaults the previous step just emptied. The
    /// zone and subscription were re-read by their own steps, before the sweep.
    public func verifyDeviceClean() async -> ErasureVerdict {
        let residue = await DefaultErasureVerifier(keyManager: keyManager).verify(scope: .allData)
        var names = residue.keychainItems.map { "keychain:\($0)" }
            + residue.files.map { "file:\($0)" }
            + residue.defaultsKeys.map { "defaults:\($0)" }
        if let ubiquity = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            names += Self.files(under: ubiquity.appendingPathComponent("Documents")).map { "iCloudDrive:\($0)" }
        }
        let hint: ErasureRecoveryHint = residue.keychainItems.isEmpty ? .files : .keychain
        return .residue("traces", names: names, hint: hint)
    }

    // MARK: - Helpers

    /// Directories iOS owns inside the app container and rewrites on its own
    /// schedule. Not user data, and not the app's to delete.
    static let systemOwnedDirectories: Set<String> = [
        "SystemData",
        "SyncedPreferences",
        "Saved Application State",
        "SplashBoard",
        "HTTPStorages",
    ]

    /// Defaults keys written by Apple frameworks into the app's domain whenever
    /// they run, not by Encamera.
    static let frameworkOwnedDefaultsKeys: Set<String> = [
        "CKStartupTime",
        "CKPerBootTasks",
        "CloudKitAccountInfoCache",
        "SKTransactionUpdatesLastChecked",
        "SK2PurchaseIntentUpdatesLastChecked",
    ]

    /// Written deliberately after the defaults wipe so a later launch finishes
    /// what this run could not.
    static let tombstoneKeys: Set<String> = [
        UserDefaultKey.pendingCloudDataWipe.rawValue,
        UserDefaultKey.pendingDefaultsWipe.rawValue,
    ]

    /// Relative paths of every regular file under `directory`. A missing or
    /// empty directory yields nothing.
    static func files(under directory: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: directory,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: []) else { return [] }
        var names: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.lastPathComponent != ".DS_Store" else { continue }
            names.append(url.path.replacingOccurrences(of: directory.path + "/", with: ""))
        }
        return names
    }
}
