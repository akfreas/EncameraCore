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
        }

        residue.files = survivingFiles(scope: scope)
        residue.defaultsKeys = survivingDefaultsKeys()

        printDebug("verify scope=\(scope.screenName) clean=\(residue.isClean) \(residue.summary)")
        return residue
    }

    // MARK: - Files

    private func survivingFiles(scope: ErasureScope) -> [String] {
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
            .filter { !Self.intentionalPostEraseKeys.contains($0) }
            .sorted()
    }

    /// Written deliberately AFTER the defaults wipe, so finding them is the system
    /// working rather than residue.
    ///
    /// `pendingCloudDataWipe` is the durable "the zone delete still owes us a
    /// retry" marker — the whole point of writing it last is that it survives the
    /// wipe. Counting it would make every offline erase report failure and refuse
    /// to quit, which is precisely backwards: that path already has its own honest
    /// "iCloud data may not be deleted" alert.
    private static let intentionalPostEraseKeys: Set<String> = [
        UserDefaultKey.pendingCloudDataWipe.rawValue
    ]
}
