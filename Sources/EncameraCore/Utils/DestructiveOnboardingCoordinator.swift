//
//  DestructiveOnboardingCoordinator.swift
//  EncameraCore
//
//  The destructive "delete my iCloud data" path for the returning user who does
//  NOT have their key (ENC-94). The riskiest flow in the multi-device project: it
//  deletes user data by design and sits directly on the tombstone landmine
//  (ENC-72/ENC-82).
//
//  Non-negotiables, all enforced here:
//   * It deletes iCloud *data*, never keys account-wide. It issues NO account-wide
//     keychain deletion — the user still owns their other device, and an
//     account-wide wipe would tombstone that device's key and brick it.
//   * Deletion is soft (tombstone), so it propagates and the reconciler cannot
//     resurrect it.
//   * Per-record failures are surfaced, never re-swallowed. A partial failure is
//     reported as such and stops short of clearing the marker or minting a key.
//   * It requires the account to be online, so nothing is attempted that cannot be
//     completed and verified.
//

import Foundation

public enum DestructiveOnboardingError: Error, Equatable {
    /// The CloudKit account is unavailable, so a destructive delete could neither
    /// be completed nor verified. Nothing is attempted.
    case offline
}

/// Machine-readable outcome of the destructive path. Surfaces per-record failures
/// rather than collapsing them, so the UI can report partial failure honestly
/// instead of claiming success.
public struct DestructiveOnboardingReport: Equatable, Sendable {
    public var tombstonedMedia: [String] = []
    public var tombstonedAlbums: [String] = []
    public var removedLegacyFileCount: Int = 0
    /// recordName -> error description for media that could not be tombstoned.
    public var mediaFailures: [String: String] = [:]
    /// albumID -> error description for albums that could not be tombstoned.
    public var albumFailures: [String: String] = [:]
    /// First error hit while removing legacy iCloud Drive files, if any.
    public var legacyFileError: String?
    /// Failures ENUMERATING what to delete, keyed by what was being enumerated
    /// (`"albums"`, or an albumID for its media).
    ///
    /// Separate from the tombstone failures above because they are the more
    /// dangerous kind: a `(try? await store.fetchAllAlbums()) ?? []` turned a fetch
    /// failure — CloudKit throttling, a network drop after `accountAvailable()`
    /// returned true, the query-index latency this container is prone to — into an
    /// empty album list. Nothing was then iterated, nothing failed, `hasFailures`
    /// was false, and `isCompleteSuccess` was VACUOUSLY true: the marker got
    /// cleared and a fresh key minted over media still sitting in CloudKit, whose
    /// key fingerprint had just been erased from the synced record. "I could not
    /// enumerate what to delete" is not "there was nothing to delete" — the same
    /// evidence-vs-absence distinction `ExistingDataProbe` makes with `.unresolved`.
    public var enumerationFailures: [String: String] = [:]
    /// How many live media records the probe's census said this account holds — the
    /// only reason the destructive screen was offered at all.
    public var expectedMediaCount: Int = 0
    /// Records the census counted that the sweep never tombstoned, when a post-sweep
    /// census could not confirm the zone is empty either.
    ///
    /// A THROWN enumeration is caught above; this catches the quieter half of the
    /// same bug — a fetch that succeeds but comes back short. `fetchAllAlbums` is a
    /// `CKQuery` and, unlike fetch-by-record-ID, is not strongly consistent: a stale
    /// `EncAlbum` index, or media whose album another device already hard-deleted,
    /// yields an album list that enumerates nothing. Zero iterations, zero failures,
    /// a VACUOUSLY clean report — marker cleared, fingerprints wiped, fresh key
    /// minted, and the census's media left in CloudKit permanently undecryptable
    /// with nothing left to warn the next install.
    public var censusShortfall: Int?
    /// Set when clearing the has-used marker failed. The one write that
    /// `isCompleteSuccess` claims happened, so swallowing it (it was a `try?`) let
    /// the run mint a key over a record still saying `hasUsedEncamera: true` with
    /// the old fingerprints — sending the user back to the returning-user branch on
    /// the next launch, for data they had already deleted.
    public var markerClearError: String?
    /// True only when a fresh key was generated — which happens only on a clean run.
    public var freshKeyGenerated: Bool = false

    public var hasFailures: Bool {
        !mediaFailures.isEmpty || !albumFailures.isEmpty || !enumerationFailures.isEmpty
            || legacyFileError != nil || censusShortfall != nil || markerClearError != nil
    }
    public var isCompleteSuccess: Bool { !hasFailures }

    public init() {}
}

/// Removes files left in the DEPRECATED iCloud Drive container. Reuses the same
/// root resolution as the onboarding probe's legacy sweep, which never crashes on
/// a missing ubiquity container (unlike `iCloudStorageModel.rootURL`).
enum LegacyICloudDriveEraser {
    /// `(removed count, first error description)`. A `nil` container is "nothing to
    /// remove", not a failure: a fresh install not signed into iCloud has no legacy
    /// files to delete, and that must not be reported as a partial failure.
    static func removeAll() async -> (removed: Int, error: String?) {
        guard let root = LegacyICloudDriveSweep.legacyRootURL() else { return (0, nil) }
        let fileManager = FileManager.default
        // An unreadable container is NOT clean success: it used to return `(0, nil)`,
        // which is byte-for-byte the "nothing to remove" answer, so the destructive
        // run went on to clear the has-used marker over files it never even saw.
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, "could not enumerate the legacy iCloud Drive container at \(root.lastPathComponent)")
        }

        var removed = 0
        var firstError: String?
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                if firstError == nil { firstError = "\(error)" }
            }
        }
        return (removed, firstError)
    }
}

/// Runs the destructive delete-my-iCloud-data path end to end. Independent of any
/// UI so both the EncameraCore unit tests and the ENC-72 two-device keychain test
/// can drive it directly.
public struct DestructiveOnboardingCoordinator {

    private let store: CloudKitMediaStoring
    private let keyManager: KeyManager
    private let freshKeyName: String
    private let removeLegacyICloudDriveFiles: @Sendable () async -> (removed: Int, error: String?)

    public init(store: CloudKitMediaStoring,
                keyManager: KeyManager,
                freshKeyName: String = AppConstants.defaultKeyName,
                removeLegacyICloudDriveFiles: (@Sendable () async -> (removed: Int, error: String?))? = nil) {
        self.store = store
        self.keyManager = keyManager
        self.freshKeyName = freshKeyName
        self.removeLegacyICloudDriveFiles = removeLegacyICloudDriveFiles
            ?? { await LegacyICloudDriveEraser.removeAll() }
    }

    /// Tombstones every CloudKit media record and album, removes legacy iCloud
    /// Drive files, and — ONLY on a completely clean run — clears the has-used
    /// marker (preserving the roster) and generates a fresh key. Throws
    /// `.offline` (having attempted nothing) when the account is unavailable;
    /// otherwise always returns a report, whose `isCompleteSuccess` the caller
    /// must check before treating the flow as done.
    ///
    /// `expectedMediaCount` is the probe's live-media census — the census that put
    /// the user on this screen. The sweep is cross-checked against it, so a fetch
    /// that succeeds but comes back short cannot pass for "there was nothing to
    /// delete". Callers with no census pass 0.
    public func run(expectedMediaCount: Int) async throws -> DestructiveOnboardingReport {
        // Step 7: never offer a destructive action we cannot complete or verify.
        guard await store.accountAvailable() else { throw DestructiveOnboardingError.offline }

        var report = DestructiveOnboardingReport()
        report.expectedMediaCount = expectedMediaCount

        // A failure here must NOT degrade to "no albums" — see `enumerationFailures`.
        // Bail immediately: with no album list there is nothing to delete and no way
        // to know what was missed, and continuing would only walk into the step-5
        // guard with a report that looks clean.
        let albums: [CloudKitAlbumMetadata]
        do {
            albums = try await store.fetchAllAlbums()
        } catch {
            report.enumerationFailures["albums"] = "\(error)"
            return report
        }

        // Tombstone every live media record, deduplicated by record name so an
        // item is never tombstoned twice.
        var seenRecords = Set<String>()
        for album in albums {
            let media: [CloudKitMediaMetadata]
            do {
                media = try await store.fetchMetadata(albumID: album.albumID, includeThumbnail: false)
            } catch {
                // Record and keep going: the other albums can still be drained, and
                // `hasFailures` now stops the run short of clearing the marker.
                report.enumerationFailures[album.albumID] = "\(error)"
                continue
            }
            for item in media where seenRecords.insert(item.recordName).inserted {
                do {
                    try await store.tombstone(recordName: item.recordName)
                    report.tombstonedMedia.append(item.recordName)
                } catch {
                    // Step 5: surface it, never re-swallow it.
                    report.mediaFailures[item.recordName] = "\(error)"
                }
            }
        }

        // Tombstone every album. `tombstoneAlbum` is deliberately NOT feature-flag
        // gated (see AlbumManager.tombstoneCloudKitAlbumRecord) so the delete always
        // propagates and the reconciler cannot resurrect it. Skip albums another
        // device already tombstoned.
        for album in albums where album.deletedAt == nil {
            do {
                try await store.tombstoneAlbum(albumID: album.albumID)
                report.tombstonedAlbums.append(album.albumID)
            } catch {
                report.albumFailures[album.albumID] = "\(error)"
            }
        }

        // Legacy iCloud Drive files.
        let legacy = await removeLegacyICloudDriveFiles()
        report.removedLegacyFileCount = legacy.removed
        report.legacyFileError = legacy.error

        // Cross-check the sweep against the census. A short sweep is only forgiven
        // when a fresh census can confirm the zone really is empty — which is also
        // what un-sticks the user whose census was itself stale: the retry passes
        // once the index catches up, instead of failing forever against a number
        // that can never be reached.
        if report.tombstonedMedia.count < expectedMediaCount, await !zoneConfirmedEmpty() {
            report.censusShortfall = expectedMediaCount - report.tombstonedMedia.count
        }

        // Step 5: on any failure, report and stop. The account still holds data, so
        // clearing the marker or minting a key would be claiming a success we didn't
        // achieve.
        guard report.isCompleteSuccess else { return report }

        // Step 6: clear `hasUsedEncamera` and the fingerprints, PRESERVE the roster.
        // A direct overwrite, NOT the OR-merging setter/recorder (which can only ever
        // *set* the marker). An update, not a delete — so the synchronizable record
        // is not tombstoned account-wide.
        //
        // A failure here stops the run exactly like the other failure paths: the
        // marker is the returning-user warning for the next install, and minting a
        // key over one that still says `hasUsedEncamera: true` strands the user in
        // the returning-user branch describing data they already erased.
        let existing = keyManager.getMultiDeviceState()
        do {
            try keyManager.overwriteMultiDeviceState(
                MultiDeviceState(hasUsedEncamera: false,
                                 devices: existing?.devices ?? [],
                                 keyFingerprints: [])
            )
        } catch {
            report.markerClearError = "\(error)"
            return report
        }

        // Step 3 (the landmine): NO account-wide keychain deletion. This is a fresh
        // install with no key of its own, and the user's other device still owns the
        // account key — it must survive. Step 4: mint a fresh key and let the caller
        // continue into normal auth setup.
        _ = try keyManager.generateKeyUsingRandomWords(name: freshKeyName)
        report.freshKeyGenerated = true

        return report
    }

    /// Whether a post-sweep census can positively confirm the zone holds no live
    /// media. An unavailable index or an unclassified throw is NOT a confirmation:
    /// this is the same evidence-vs-absence distinction `ExistingDataProbe` makes,
    /// applied to the verification of a delete rather than the detection of data.
    private func zoneConfirmedEmpty() async -> Bool {
        do {
            guard case .counted(let mediaCount, _) = try await store.fetchFingerprintCensus() else {
                return false
            }
            return mediaCount == 0
        } catch CloudKitMediaStoreError.zoneNotFound {
            return true
        } catch {
            return false
        }
    }
}
