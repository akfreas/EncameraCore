//
//  CloudKitFlightCheck.swift
//  EncameraCore
//
//  Manual, end-to-end smoke test of the CloudKit storage plane. Runs the *real*
//  app code paths (account gating, zone bootstrap, push subscription, album
//  creation, encrypt + upload, delta sync, cold-cache server download + decrypt,
//  thumbnail fetch, delete + cross-device propagation) with dummy data and the
//  existing keychain key, so a human can see exactly where iCloud albums break.
//
//  Drives the `ICloudFlightCheckView` workbench (behind the `iCloudFlightCheck`
//  feature toggle). Steps run in order and HALT on the first failure; each step
//  reports a readable message plus raw detail, and logs context via printDebug.
//
//  Note on the download steps: a normal `loadMedia` is served from the local cache
//  the upload just wrote, so it does NOT prove the blob is on the server. The
//  download/thumbnail steps deliberately EVICT the cache first, forcing a true
//  fetch from CloudKit. The run deletes what it creates — step 11 the album it
//  makes to test the cascade, step 12 the record uploaded at step 7 — so a green
//  run leaves only its (empty) test album behind. A halted run tears down what it
//  got to; `removeTestAlbums` clears leftovers from runs that could not.
//

import Foundation
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Step model

/// The lifecycle state of a single flight-check step, rendered by the workbench.
public enum FlightCheckStepStatus: Equatable {
    case pending
    case running
    case passed(detail: String?)
    case failed(message: String, detail: String?)
}

/// A named step in the flight-check sequence.
public struct FlightCheckStep: Identifiable, Equatable {
    public let id: Int
    public let title: String
}

// MARK: - Typed failures

/// Failures specific to the flight check (CloudKit errors are translated via
/// `mapCKError`). Each carries a concise user-facing `message` and a verbose
/// `detail` for the expandable disclosure / logs.
public enum FlightCheckError: Error {
    case entitlement(container: String, underlying: Error)
    case account(status: CKAccountStatus)
    case zoneMissing
    case noKey
    case uploadReturnedNil
    case notListed(id: String, found: Int)
    case emptyDownload
    case byteMismatch(expected: Int, got: Int)
    case emptyThumbnail
    case stillListedAfterDelete(id: String)
    case imageEncodingFailed
    case cancelIgnored(detail: String)
    case restartReportedNoProgress
    case cancelledDownloadStillCompleted(seconds: TimeInterval)
    case downloadTooFastToCatch(bytes: Int, seconds: TimeInterval?)
    case childNeverReachedServer(recordName: String)
    case childSurvivedAlbumDelete(recordName: String, waited: TimeInterval)
    case internalState(String)

    var message: String {
        switch self {
        case .entitlement(let container, _):
            return "CloudKit entitlement not configured for \(container)"
        case .account(let status):
            return "iCloud account not available (\(CloudKitFlightCheck.describe(status)))"
        case .zoneMissing:
            return "Custom zone could not be created on the server"
        case .noKey:
            return "No encryption key — set up your key first"
        case .uploadReturnedNil:
            return "Upload returned no record"
        case .notListed:
            return "Uploaded record did not appear in the synced index"
        case .emptyDownload:
            return "Server download was empty"
        case .byteMismatch:
            return "Round-trip bytes did not match the original"
        case .emptyThumbnail:
            return "Thumbnail fetched from the server was empty"
        case .stillListedAfterDelete:
            return "Record was still in the index after delete"
        case .imageEncodingFailed:
            return "Could not build the dummy test image"
        case .cancelIgnored:
            return "A cancelled download did not stop"
        case .restartReportedNoProgress:
            return "A download restarted after a cancel reported no progress"
        case .cancelledDownloadStillCompleted:
            return "A cancelled download finished anyway and cached its blob"
        case .downloadTooFastToCatch:
            return "Could not catch the probe download in flight"
        case .childNeverReachedServer:
            return "The probe photo never reached the server, so the cascade cannot be tested"
        case .childSurvivedAlbumDelete:
            return "Deleting the album left its media behind on the server"
        case .internalState(let what):
            return "Internal flight-check state error: \(what)"
        }
    }

    var detail: String {
        switch self {
        case .entitlement(let container, let underlying):
            return "Verify the app's entitlement includes the CloudKit service under "
                + "com.apple.developer.icloud-services and that "
                + "com.apple.developer.icloud-container-identifiers contains \(container). "
                + "Underlying: \(String(reflecting: underlying))"
        case .account(let status):
            return "CKAccountStatus = \(CloudKitFlightCheck.describe(status)) (raw \(status.rawValue)). "
                + "Sign in to iCloud in Settings and ensure iCloud Drive is enabled."
        case .zoneMissing:
            return "Even after resetting the zone-created flag and calling ensureZoneExists(), "
                + "\(CloudKitSchema.zoneName) is not present in \(CloudKitSchema.containerID)'s private DB. "
                + "Check the container exists in the CloudKit dashboard and that the account has CloudKit access."
        case .noKey:
            return "KeyManager.currentKey is nil. The flight check encrypts with the existing keychain key; create or unlock a key, then retry."
        case .uploadReturnedNil:
            return "CloudKitFileAccess.save returned nil for the dummy photo — the CloudKit save path produced no EncryptedMedia."
        case .notListed(let id, let found):
            return "After reconcile(), enumerate() returned \(found) item(s), none matching record id \(id). The blob may have written but the delta sync / index did not surface it."
        case .emptyDownload:
            return "After evicting the local cache, loadMedia() pulled the blob from CloudKit but produced no readable bytes — the asset may not be on the server."
        case .byteMismatch(let expected, let got):
            return "Downloaded \(got) bytes from the server but expected \(expected). The blob round-tripped but did not decrypt to the original — possible encryption-key or asset-corruption issue."
        case .emptyThumbnail:
            return "After evicting the local thumbnail, loadMediaPreview() fetched the eager encThumbnail asset from CloudKit but it decoded to no data — the thumbnail asset may not have uploaded."
        case .stillListedAfterDelete(let id):
            return "After delete + reconcile, record id \(id) is still present in the synced index — the record delete did not reach the server, or the zone change feed did not report it back."
        case .imageEncodingFailed:
            return "UIGraphicsImageRenderer / jpegData produced no data for the synthetic test image."
        case .cancelIgnored(let detail):
            return "The probe cancelled an in-flight CloudKit download and \(detail). "
                + "Cancelling must release the caller immediately and stop the transfer — otherwise the user's "
                + "Cancel only stops them watching, and the next attempt attaches to the abandoned download."
        case .restartReportedNoProgress:
            return "After cancelling, the download was started again and its progress closure was never called with "
                + "a fraction above 0. That is the frozen progress bar users report: the restart joined an in-flight "
                + "fetch whose progress was wired to the caller that already walked away."
        case .cancelledDownloadStillCompleted(let seconds):
            return "The probe cancelled a download and then waited \(String(format: "%.1f", seconds * 3 + 1))s — several times "
                + "the \(String(format: "%.2f", seconds))s a cold download of this payload takes — and the blob was in the cache "
                + "anyway. The transfer ignored the cancel and ran to completion, which burns the user's data after they "
                + "explicitly asked it to stop, and leaves the next attempt attaching to a download nobody is listening to."
        case .downloadTooFastToCatch(let bytes, let seconds):
            let measured = seconds.map { "A full cold download of it took only \(String(format: "%.2f", $0))s. " } ?? ""
            return "The \(bytes)-byte probe payload downloads too fast on this link to test cancellation. \(measured)"
                + "A cancel that released nobody would have looked instant here, so the step cannot tell a working "
                + "cancel from a broken one. Not a product failure — but reported as a failure rather than a silent "
                + "pass. Raise `makeIncompressibleJPEG`'s pixelsPerSide until a cold download takes longer than "
                + "`minimumUsefulDownloadSeconds`."
        case .childNeverReachedServer(let recordName):
            return "Record \(recordName) was uploaded into the flight-check album but a fetch-by-record-ID never "
                + "returned it. Nothing can be concluded about the album-delete cascade from a child that was "
                + "never on the server, so the step fails here rather than passing vacuously on its absence."
        case .childSurvivedAlbumDelete(let recordName, let waited):
            return "The album's EncAlbum record was deleted and \(String(format: "%.0f", waited))s later its child "
                + "\(recordName) was still on the server. Every EncMedia carries a CKRecord.Reference to its album "
                + "with action .deleteSelf, so deleting the album must take its media — and their full-size encBlob "
                + "assets — with it. A surviving child means those blobs stay against the user's iCloud quota with "
                + "no album left to reach them from, and receiving devices keep index entries for media whose parent "
                + "is gone. Check the reference and its delete action on the uploaded record in the Dashboard."
        case .internalState(let what):
            return what
        }
    }
}

/// Collects the download fractions one `loadMedia` call was handed, so the
/// cancel/restart step can tell "the bar moved" from "the bar sat there".
final class DownloadProgressRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var fractions: [Double] = []
    private var leftDownloading = false

    var downloadFractions: [Double] { lock.lock(); defer { lock.unlock() }; return fractions }

    /// True once any fraction beyond the initial 0 arrived.
    var sawDownloadProgress: Bool { downloadFractions.contains { $0 > 0 } }

    /// The first fraction that proves bytes are moving: not 0 (nothing yet) and
    /// not 1 (already done).
    var midFlightFraction: Double? { downloadFractions.first { $0 > 0 && $0 < 1 } }

    /// The load moved past downloading (decrypting/loaded) — there is nothing
    /// left to catch mid-flight.
    var isPastDownloading: Bool { lock.lock(); defer { lock.unlock() }; return leftDownloading }

    func record(_ status: FileLoadingStatus) {
        lock.lock()
        defer { lock.unlock() }
        switch status {
        case .downloading(let fraction): fractions.append(fraction)
        case .decrypting, .loaded: leftDownloading = true
        case .notLoaded: break
        }
    }
}

// MARK: - Engine

/// Runs the CloudKit flight-check sequence. Construct once per run; not Sendable
/// (the run is sequential and single-flight from the workbench view model).
public final class CloudKitFlightCheck: DebugPrintable {

    /// The ordered checks. Indices are stable and used as `FlightCheckStepStatus`
    /// keys by the view model.
    public static let steps: [FlightCheckStep] = [
        .init(id: 0,  title: "CloudKit entitlement configured"),
        .init(id: 1,  title: "iCloud account available"),
        .init(id: 2,  title: "CloudKit container reachable"),
        .init(id: 3,  title: "Custom zone ready"),
        .init(id: 4,  title: "Push subscription registered"),
        .init(id: 5,  title: "Encryption key available"),
        .init(id: 6,  title: "Create test CloudKit album"),
        .init(id: 7,  title: "Encrypt & upload test photo"),
        .init(id: 8,  title: "Sync & list uploaded item"),
        .init(id: 9,  title: "Download blob from server (cold cache)"),
        .init(id: 10, title: "Thumbnail from server (cold cache)"),
        .init(id: 11, title: "Deleting an album takes its media with it"),
        .init(id: 12, title: "Delete removes the record everywhere"),
        // Last deliberately. The run halts on the first failure, and this step
        // cannot reach a verdict at all on a fast link (see `downloadTooFastToCatch`)
        // — ahead of the others it would stop the functional steps from ever being
        // checked on the rig, which is where they matter most.
        .init(id: 13, title: "Cancel & restart a download"),
    ]

    private let keyManager: KeyManager
    private let albumManager: AlbumManaging
    private let container: CloudKitContainer

    // Carried across steps so the upload/list/download/delete steps reuse the album.
    private var testAlbum: Album?
    private var cloud: CloudKitFileAccess?
    private var savedMedia: InteractableMedia<EncryptedMedia>?
    private var originalJPEG: Data?
    /// The multi-megabyte record the cancel/restart step uploads. Held so a halted
    /// run reclaims it — it is far too big to leak into the user's iCloud quota.
    private var cancelProbeMedia: InteractableMedia<EncryptedMedia>?
    /// The album, access and child the cascade step creates. Held only until the
    /// cascade removes them, so a step that fails mid-way still reclaims what it
    /// just wrote instead of leaking a record and its blob into the user's quota.
    private var cascadeAlbum: Album?
    private var cascadeCloud: CloudKitFileAccess?
    private var cascadeProbeMedia: InteractableMedia<EncryptedMedia>?

    public init(keyManager: KeyManager,
                albumManager: AlbumManaging,
                container: CloudKitContainer = .shared) {
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.container = container
    }

    /// Runs every step in order, reporting status transitions through `onUpdate`.
    /// Stops at the first failure (later steps remain `.pending`) and tears down
    /// its own test data. A run that reaches the end has already deleted the album
    /// it created at step 11 and the record it uploaded at step 7.
    public func run(onUpdate: @MainActor @escaping (_ index: Int, _ status: FlightCheckStepStatus) -> Void) async {
        printDebug("Starting iCloud Flight Check — container=\(CloudKitSchema.containerID), zone=\(CloudKitSchema.zoneName)")
        for step in Self.steps {
            if Task.isCancelled {
                printDebug("iCloud Flight Check cancelled before step \(step.id) — cleaning up.")
                scheduleCleanup()
                return
            }
            await onUpdate(step.id, .running)
            printDebug("▶︎ step \(step.id) [\(step.title)] running")
            do {
                let detail = try await runStep(step.id)
                printDebug("✓ step \(step.id) [\(step.title)] passed\(detail.map { " — \($0)" } ?? "")")
                await onUpdate(step.id, .passed(detail: detail))
            } catch {
                let (message, detail) = describe(error)
                printDebug("✗ step \(step.id) [\(step.title)] FAILED: \(message)\n    detail: \(detail)")
                await onUpdate(step.id, .failed(message: message, detail: detail))
                printDebug("Halting iCloud Flight Check at step \(step.id).")
                scheduleCleanup()
                return
            }
        }
        printDebug("iCloud Flight Check complete — all steps passed. Every record the run uploaded was deleted; the empty test album is left for inspection: \(testAlbum?.name ?? "?")")
    }

    /// Best-effort teardown for a run that halted (failure or cancellation) before
    /// the delete step: reclaims the uploaded record — its full-size `encBlob` +
    /// `encThumbnail` CKAssets would otherwise sit orphaned in the user's private
    /// database forever, since every run uses a fresh UUID-suffixed album and no
    /// re-run ever touches them — and removes the now-useless test album. Runs
    /// detached so it still executes when the run's own task was cancelled (e.g.
    /// the workbench view was dismissed mid-run).
    private func scheduleCleanup() {
        let cloud = self.cloud
        let saved = self.savedMedia
        let probe = self.cancelProbeMedia
        let cascadeProbe = self.cascadeProbeMedia
        let cascadeCloud = self.cascadeCloud
        let cascadeAlbum = self.cascadeAlbum
        let album = self.testAlbum
        let albumManager = self.albumManager
        Task.detached {
            if let cloud, let saved {
                try? await cloud.delete(media: [saved])
            }
            if let cloud, let probe {
                try? await cloud.delete(media: [probe])
            }
            if let cascadeCloud, let cascadeProbe {
                try? await cascadeCloud.delete(media: [cascadeProbe])
            }
            if let cascadeAlbum {
                albumManager.delete(album: cascadeAlbum)
            }
            if let album {
                albumManager.delete(album: album)
            }
        }
    }

    // MARK: Test-album housekeeping

    /// The name prefix every flight-check album uses. `removeTestAlbums` keys on it.
    public static let testAlbumNamePrefix = "FlightCheck "

    /// Deletes every album left behind by previous flight-check runs (marker,
    /// local cache, and index — see `AlbumManager.delete`). Every run leaves its
    /// test album behind, so these accumulate without this.
    /// Returns how many albums were removed.
    @discardableResult
    public static func removeTestAlbums(albumManager: AlbumManaging) -> Int {
        let testAlbums = albumManager.fetchAlbumsFromSources(includingHidden: true)
            .filter { $0.name.hasPrefix(testAlbumNamePrefix) }
        for album in testAlbums {
            albumManager.delete(album: album)
        }
        return testAlbums.count
    }

    private func runStep(_ index: Int) async throws -> String? {
        switch index {
        case 0:  return try await checkEntitlement()
        case 1:  return try await checkAccount()
        case 2:  return try await checkContainerReachable()
        case 3:  return try await checkZone()
        case 4:  return try await checkSubscription()
        case 5:  return try checkKey()
        case 6:  return try checkCreateAlbum()
        case 7:  return try await checkUpload()
        case 8:  return try await checkSyncAndList()
        case 9:  return try await checkColdDownload()
        case 10: return try await checkColdThumbnail()
        case 11: return try await checkAlbumDeleteCascade()
        case 12: return try await checkDelete()
        case 13: return try await checkCancelAndRestartDownload()
        default: return nil
        }
    }

    // MARK: Steps

    /// There is no runtime API to read our own entitlements, so we infer the
    /// CloudKit entitlement by probing the private DB and classifying the error.
    /// Only entitlement/container-class errors fail here; a missing account or a
    /// network error is deferred to the dedicated later steps.
    private func checkEntitlement() async throws -> String? {
        do {
            _ = try await container.privateDB.allRecordZones()
            return "Container \(CloudKitSchema.containerID) accepted a private-DB request"
        } catch let ckError as CKError {
            switch ckError.code {
            case .missingEntitlement, .badContainer, .badDatabase:
                throw FlightCheckError.entitlement(container: CloudKitSchema.containerID, underlying: ckError)
            default:
                return "Entitlement present (probe returned .\(ckError.code) — handled by a later step)"
            }
        } catch {
            return "Entitlement present (probe deferred: \(error.localizedDescription))"
        }
    }

    private func checkAccount() async throws -> String? {
        let status = await container.accountStatus()
        guard status == .available else {
            throw FlightCheckError.account(status: status)
        }
        return "Account status: available"
    }

    private func checkContainerReachable() async throws -> String? {
        let zones = try await container.privateDB.allRecordZones()
        return "Reached \(CloudKitSchema.containerID) private DB (\(zones.count) zone(s))"
    }

    /// Verifies the custom zone actually exists in THIS container by fetching the
    /// zone list — never trusting the persisted "zone created" flag, which can be
    /// stale (a flag set for a previous container/account silently suppresses
    /// creation, leaving the new container with no zone). If it's missing, force a
    /// recreate and re-verify.
    private func checkZone() async throws -> String? {
        if try await zoneExistsOnServer() {
            return "Zone '\(CloudKitSchema.zoneName)' exists in \(CloudKitSchema.containerID)"
        }
        container.resetZoneCreatedFlag()
        try await container.ensureZoneExists()
        guard try await zoneExistsOnServer() else {
            throw FlightCheckError.zoneMissing
        }
        return "Zone '\(CloudKitSchema.zoneName)' created in \(CloudKitSchema.containerID)"
    }

    private func zoneExistsOnServer() async throws -> Bool {
        let zones = try await container.privateDB.allRecordZones()
        return zones.contains { $0.zoneID.zoneName == CloudKitSchema.zoneName }
    }

    /// Registers the zone push subscription — the same call the coordinator makes in
    /// `startObserving()`. Zone-level, so it needs no album.
    private func checkSubscription() async throws -> String? {
        let store = CloudKitStoreProvider.makeStore("flightcheck")
        try await store.registerZoneSubscription()
        return "Zone push subscription registered"
    }

    private func checkKey() throws -> String? {
        guard let key = keyManager.currentKey else {
            throw FlightCheckError.noKey
        }
        return "Using key '\(key.name)' (\(key.keyBytes.count) bytes)"
    }

    private func checkCreateAlbum() throws -> String? {
        // A UUID suffix guarantees a unique album name (and therefore a unique
        // name-derived storage directory / discovery marker) even across rapid
        // re-runs in the same second or leftover albums from previous runs.
        let name = "\(Self.testAlbumNamePrefix)\(Self.timestamp()) #\(String(NSUUID().uuidString.prefix(8)))"
        let album = try albumManager.create(name: name, storageOption: .cloudKit)
        testAlbum = album
        return "Created album '\(name)' (id \(album.id))"
    }

    private func checkUpload() async throws -> String? {
        guard let album = testAlbum else { throw FlightCheckError.internalState("no test album from step 6") }
        let jpeg = try Self.makeDummyJPEG()
        originalJPEG = jpeg

        let cleartext = CleartextMedia(source: jpeg, mediaType: .photo, id: NSUUID().uuidString)
        let interactable = try InteractableMedia(underlyingMedia: [cleartext])

        // Exact cloud path: CloudKitFileAccess (production wiring — shared coordinator
        // via the registry, shared blob cache) → encrypt (SecretFileHandlerV2) →
        // CloudKitMediaStore.upload (writes the encBlob + encThumbnail CKAssets).
        let cloud = await CloudKitFileAccess(album: album, albumManager: albumManager)
        self.cloud = cloud
        await cloud.start()

        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date()
        metadata.encryptionDate = Date()
        metadata.originalMediaType = "photo"
        metadata.originalExtension = "jpg"
        metadata.originalFileSize = UInt64(jpeg.count)

        guard let saved = try await cloud.save(media: interactable, metadata: metadata, progress: { _ in }) else {
            throw FlightCheckError.uploadReturnedNil
        }
        savedMedia = saved
        return "Uploaded record id \(saved.id) — \(jpeg.count) bytes encrypted"
    }

    private func checkSyncAndList() async throws -> String? {
        guard let cloud, let saved = savedMedia else {
            throw FlightCheckError.internalState("no upload to verify from step 7")
        }
        _ = await cloud.reconcile()
        let listed = await cloud.enumerate()
        guard listed.contains(where: { $0.id == saved.id }) else {
            throw FlightCheckError.notListed(id: saved.id, found: listed.count)
        }
        return "Synced index lists \(listed.count) item(s), including the test record"
    }

    /// Evicts the locally-cached ciphertext, then downloads + decrypts from CloudKit.
    /// This is the real proof the blob is durable server-side (a plain `loadMedia`
    /// would be served from the cache the upload just wrote). A freshly-created record
    /// can briefly read back as `notFound` (CloudKit asset/record propagation), so the
    /// fetch is retried with backoff before it's treated as a genuine failure.
    private func checkColdDownload() async throws -> String? {
        guard let cloud, let saved = savedMedia, let original = originalJPEG else {
            throw FlightCheckError.internalState("no upload to download from step 7")
        }
        try await cloud.evictCachedBlob(for: saved.id, type: .photo)
        let decrypted = try await retrying("cold blob download") {
            try await cloud.loadMedia(media: saved, progress: { _ in })
        }
        guard let item = decrypted.underlyingMedia.first else { throw FlightCheckError.emptyDownload }
        let bytes = item.data ?? item.url.flatMap { try? Data(contentsOf: $0) }
        guard let downloaded = bytes, !downloaded.isEmpty else { throw FlightCheckError.emptyDownload }
        guard downloaded == original else {
            throw FlightCheckError.byteMismatch(expected: original.count, got: downloaded.count)
        }
        return "Downloaded \(downloaded.count) bytes from CloudKit — match the original"
    }

    /// Evicts the local thumbnail, then fetches + decrypts the eager `encThumbnail`
    /// asset from CloudKit (the gallery-grid path). Retried with backoff for the same
    /// propagation reason as the blob download.
    private func checkColdThumbnail() async throws -> String? {
        guard let cloud, let saved = savedMedia else {
            throw FlightCheckError.internalState("no upload to preview from step 7")
        }
        try await cloud.evictThumbnail(for: saved.id)
        let preview = try await retrying("cold thumbnail fetch") {
            try await cloud.loadMediaPreview(for: saved)
        }
        guard let bytes = preview.thumbnailMedia.data, !bytes.isEmpty else {
            throw FlightCheckError.emptyThumbnail
        }
        return "Fetched + decoded \(bytes.count)-byte thumbnail from CloudKit"
    }

    /// The user-visible download loop this branch exists for: start a download,
    /// cancel it mid-transfer, start it again.
    ///
    /// Both halves are regressions we have shipped:
    ///   1. Cancel used to release nobody — awaiting the shared fetch task is not a
    ///      cancellation point, so the caller stayed parked for the whole transfer
    ///      (and CloudKit kept downloading).
    ///   2. The restart attached to that abandoned fetch, whose progress closure
    ///      belonged to the cancelled caller, so its progress bar never moved.
    ///
    /// Uses its own multi-megabyte payload: the flight check's dummy photo arrives
    /// too fast to ever be caught mid-flight, and only a genuinely in-flight
    /// download proves anything here.
    private func checkCancelAndRestartDownload() async throws -> String? {
        guard let cloud else { throw FlightCheckError.internalState("no CloudKit album from step 6") }

        let payload = try Self.makeIncompressibleJPEG()
        let cleartext = CleartextMedia(source: payload, mediaType: .photo, id: NSUUID().uuidString)
        let interactable = try InteractableMedia(underlyingMedia: [cleartext])
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date()
        metadata.encryptionDate = Date()
        metadata.originalMediaType = "photo"
        metadata.originalExtension = "jpg"
        metadata.originalFileSize = UInt64(payload.count)

        guard let probe = try await cloud.save(media: interactable, metadata: metadata, progress: { _ in }) else {
            throw FlightCheckError.uploadReturnedNil
        }
        cancelProbeMedia = probe
        _ = await cloud.reconcile()

        // 1. Time a full cold download of this exact payload. Everything below is
        //    scaled off it: the rig's link does tens of MB/s, so any hard-coded
        //    "cancel after N seconds" either misses the transfer entirely or waits
        //    long enough that a broken cancel looks instant too.
        try await cloud.evictCachedBlob(for: probe.id, type: .photo)
        let baselineStarted = Date()
        _ = try await cloud.loadMedia(media: probe, progress: { _ in })
        let coldSeconds = Date().timeIntervalSince(baselineStarted)
        guard coldSeconds >= Self.minimumUsefulDownloadSeconds else {
            throw FlightCheckError.downloadTooFastToCatch(bytes: payload.count, seconds: coldSeconds)
        }

        // 2. Start it again and cancel a fraction of the way in, so the cancel
        //    lands with most of the transfer still to go.
        try await cloud.evictCachedBlob(for: probe.id, type: .photo)
        let firstAttempt = DownloadProgressRecorder()
        let cancelled = Task {
            try await cloud.loadMedia(media: probe, progress: { firstAttempt.record($0) })
        }
        // Cancel the instant bytes are provably moving, rather than after a fixed
        // slice of the cold baseline. This second fetch is served warm and routinely
        // beats that baseline several times over, so any stopwatch-derived grace
        // period expires when the transfer is already finished.
        let startedWaiting = Date()
        let catchDeadline = startedWaiting.addingTimeInterval(coldSeconds * 3 + 1)
        while firstAttempt.midFlightFraction == nil,
              !firstAttempt.isPastDownloading,
              Date() < catchDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let graceSeconds = Date().timeIntervalSince(startedWaiting)

        let caughtAt = firstAttempt.midFlightFraction ?? firstAttempt.downloadFractions.last ?? 0
        // Either the transfer left the downloading phase, or it never reported a
        // fraction between 0 and 1 at all: the cancel below would land on nothing and
        // the load would return the media whatever the product does. That is this rig
        // being faster than the payload, not a cancel being ignored, and the two must
        // not report the same way — the step says it could not judge rather than
        // accusing the product of a defect it did not commit.
        if firstAttempt.isPastDownloading || firstAttempt.midFlightFraction == nil {
            cancelled.cancel()
            _ = await Self.outcome(of: cancelled, timeout: coldSeconds * 3 + 1)
            try? await cloud.delete(media: [probe])
            cancelProbeMedia = nil
            throw FlightCheckError.downloadTooFastToCatch(bytes: payload.count, seconds: coldSeconds)
        }
        let cancelledAt = Date()
        cancelled.cancel()
        // A working cancel releases its caller in milliseconds. Allow it the whole
        // remaining transfer plus slack, so the only way to exceed this is to have
        // sat out the download — which is the defect.
        let released = await Self.outcome(of: cancelled, timeout: coldSeconds * 3 + 1)
        let releaseSeconds = Date().timeIntervalSince(cancelledAt)
        switch released {
        case .cancelled:
            break
        case .stillRunning:
            throw FlightCheckError.cancelIgnored(detail: "the cancelled download was still parked \(String(format: "%.1f", releaseSeconds))s later")
        case .finishedAnyway:
            throw FlightCheckError.cancelIgnored(detail: "the cancelled download ran to completion and returned the media anyway (\(String(format: "%.2f", releaseSeconds))s after the cancel)")
        case .failed(let error):
            throw error
        }

        // 3. The timing-free proof that the transfer really stopped: give the
        //    abandoned fetch several times as long as it needed, then check the
        //    blob cache. A download that secretly ran on to completion stores its
        //    blob there — on any link, however fast.
        try await Task.sleep(nanoseconds: UInt64((coldSeconds * 3 + 1) * 1_000_000_000))
        if await cloud.isBlobCached(for: probe.id, type: .photo) {
            throw FlightCheckError.cancelledDownloadStillCompleted(seconds: coldSeconds)
        }

        // 4. Restart it. This is the download the user watches after tapping
        //    Cancel — and the one that used to sit frozen at its last percentage.
        let restart = DownloadProgressRecorder()
        let restartStarted = Date()
        let decrypted = try await cloud.loadMedia(media: probe, progress: { restart.record($0) })
        let restartSeconds = Date().timeIntervalSince(restartStarted)
        guard restart.sawDownloadProgress else {
            throw FlightCheckError.restartReportedNoProgress
        }
        guard let bytes = decrypted.underlyingMedia.first?.data, !bytes.isEmpty else {
            throw FlightCheckError.emptyDownload
        }
        guard bytes == payload else {
            throw FlightCheckError.byteMismatch(expected: payload.count, got: bytes.count)
        }

        // Reclaim the probe's quota now — it is an order of magnitude bigger than
        // the flight check's own test record.
        try? await cloud.delete(media: [probe])
        cancelProbeMedia = nil

        return "\(payload.count)-byte payload downloads cold in \(String(format: "%.2f", coldSeconds))s; "
            + "caught in flight after \(String(format: "%.2f", graceSeconds))s (at \(Int(caughtAt * 100))%) and "
            + "cancelled — released in "
            + "\(String(format: "%.2f", releaseSeconds))s, nothing cached afterwards; the restart reported "
            + "\(restart.downloadFractions.count) progress updates and returned all \(bytes.count) bytes in "
            + "\(String(format: "%.2f", restartSeconds))s"
    }

    /// Below this, a cold download is over before anything could meaningfully be
    /// cancelled and the step cannot judge anything.
    private static let minimumUsefulDownloadSeconds: TimeInterval = 0.25

    private enum CancelOutcome {
        /// Stopped, as asked.
        case cancelled
        /// Ignored the cancel and delivered the media anyway.
        case finishedAnyway
        /// Still hadn't returned when the wait expired.
        case stillRunning
        case failed(Error)
    }

    /// Waits — with a ceiling — for a cancelled download to unwind, so a build that
    /// ignores cancellation fails this step instead of hanging the workbench.
    private static func outcome<T>(of task: Task<T, Error>, timeout: TimeInterval) async -> CancelOutcome {
        await withTaskGroup(of: CancelOutcome.self) { group in
            group.addTask {
                do {
                    _ = try await task.value
                    return .finishedAnyway
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .stillRunning
            }
            let first = await group.next() ?? .stillRunning
            group.cancelAll()
            return first
        }
    }

    /// Retries `op` on transient failures (e.g. a just-created record/asset that hasn't
    /// propagated yet) with a fixed backoff. Re-throws the last error if all attempts
    /// fail. Logs each attempt so a persistent failure is distinguishable from a race.
    private func retrying<T>(_ label: String,
                             attempts: Int = 6,
                             delaySeconds: Double = 1.5,
                             _ op: () async throws -> T) async throws -> T {
        var lastError: Error = FlightCheckError.internalState("no attempts made for \(label)")
        for attempt in 1...attempts {
            do {
                let value = try await op()
                if attempt > 1 { printDebug("\(label): succeeded on attempt \(attempt)/\(attempts)") }
                return value
            } catch {
                lastError = error
                printDebug("\(label): attempt \(attempt)/\(attempts) failed — \(mapCKError(error).description)")
                if attempt < attempts {
                    // Propagate cancellation (Task.sleep throws CancellationError)
                    // instead of swallowing it — a dismissed workbench must be able
                    // to stop the retry loop, not just wait it out.
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }
        throw lastError
    }

    /// Deletes the uploaded record and verifies it disappears from the synced index.
    ///
    /// A delete is one server op that takes the record and both its assets with it;
    /// the reconcile then proves the zone change feed reported that deletion back,
    /// which is the same signal every other device acts on. Leaves the (now empty)
    /// album for inspection.
    private func checkDelete() async throws -> String? {
        guard let cloud, let saved = savedMedia else {
            throw FlightCheckError.internalState("no upload to delete from step 7")
        }
        try await cloud.delete(media: [saved])
        _ = await cloud.reconcile()
        let listed = await cloud.enumerate()
        guard !listed.contains(where: { $0.id == saved.id }) else {
            throw FlightCheckError.stillListedAfterDelete(id: saved.id)
        }
        return "Record deleted on the server and removed from the synced index"
    }

    /// Deleting an album must take its media with it. Every `EncMedia` carries a
    /// `CKRecord.Reference` to its `EncAlbum` parent with action `.deleteSelf`, so
    /// the server-side cascade is what reclaims the blobs when an album goes. No
    /// mock can answer whether that cascade fires — it is CloudKit behavior — which
    /// is why it is checked here.
    ///
    /// Self-contained: it creates its own album and its own child rather than
    /// consuming the run's test album, because the album it deletes cannot survive
    /// the step and the later steps still need one. It proves the child is ON the
    /// server before deleting anything — an absence that was never a presence would
    /// pass this step for the wrong reason — then deletes the album through
    /// `AlbumManager.delete`, the same call the album's "Delete Album" makes.
    private func checkAlbumDeleteCascade() async throws -> String? {
        let name = "\(Self.testAlbumNamePrefix)Cascade \(Self.timestamp()) #\(String(NSUUID().uuidString.prefix(8)))"
        let album = try albumManager.create(name: name, storageOption: .cloudKit)
        cascadeAlbum = album
        guard let albumID = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) else {
            throw FlightCheckError.internalState("could not derive the album id hash for '\(album.name)'")
        }

        let cloud = await CloudKitFileAccess(album: album, albumManager: albumManager)
        cascadeCloud = cloud
        await cloud.start()

        let jpeg = try Self.makeDummyJPEG()
        let cleartext = CleartextMedia(source: jpeg, mediaType: .photo, id: NSUUID().uuidString)
        let interactable = try InteractableMedia(underlyingMedia: [cleartext])
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date()
        metadata.encryptionDate = Date()
        metadata.originalMediaType = "photo"
        metadata.originalExtension = "jpg"
        metadata.originalFileSize = UInt64(jpeg.count)
        guard let probe = try await cloud.save(media: interactable, metadata: metadata, progress: { _ in }) else {
            throw FlightCheckError.uploadReturnedNil
        }
        cascadeProbeMedia = probe
        let childRecordName = MediaRecordName.componentRecordName(mediaID: probe.id, type: .photo)

        // Fetch-by-record-ID, never the `fetchMetadata` query: that index is
        // eventually consistent, so it can report a live record as absent and a
        // deleted one as present — both of which would decide this step wrongly.
        let store = CloudKitStoreProvider.makeStore(albumID)
        let landed = await Self.poll(timeout: 60) {
            let found = try? await store.fetchRecordMetadata(recordName: childRecordName)
            return (found ?? nil) != nil
        }
        guard landed else { throw FlightCheckError.childNeverReachedServer(recordName: childRecordName) }

        albumManager.delete(album: album)
        // The album and its child are gone from here on; drop the handles so a
        // cleanup pass does not try to delete them a second time.
        cascadeAlbum = nil
        cascadeCloud = nil

        let started = Date()
        let cascaded = await Self.poll(timeout: 120) {
            let found = try? await store.fetchRecordMetadata(recordName: childRecordName)
            return (found ?? nil) == nil
        }
        let waited = Date().timeIntervalSince(started)
        guard cascaded else {
            throw FlightCheckError.childSurvivedAlbumDelete(recordName: childRecordName, waited: waited)
        }
        cascadeProbeMedia = nil
        return "Album delete cascaded to its media in \(String(format: "%.1f", waited))s — "
            + "child record \(childRecordName) is gone from the server"
    }

    // MARK: Helpers

    /// Polls `condition` every second until it holds or `timeout` elapses.
    /// The cascade is server-side work with no completion signal to await, and the
    /// album record's own delete is dispatched asynchronously by `AlbumManager`, so
    /// the only honest question is "did this become true within a budget".
    private static func poll(timeout: TimeInterval,
                             until condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return await condition()
    }

    /// Splits an error into a concise message and verbose detail for the UI/logs.
    private func describe(_ error: Error) -> (message: String, detail: String) {
        if let fcError = error as? FlightCheckError {
            return (fcError.message, fcError.detail)
        }
        if let ckError = error as? CKError {
            let mapped = mapCKError(ckError)
            let detail = "CKError .\(ckError.code) (code \(ckError.code.rawValue))\nuserInfo: \(ckError.errorUserInfo)"
            return (mapped.description, detail)
        }
        let mapped = mapCKError(error)
        return (mapped.description, String(reflecting: error))
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "no account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could not determine"
        case .temporarilyUnavailable: return "temporarily unavailable"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    /// A small solid-color JPEG, used as the dummy photo payload.
    private static func makeDummyJPEG() throws -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw FlightCheckError.imageEncodingFailed
        }
        return data
        #else
        throw FlightCheckError.imageEncodingFailed
        #endif
    }

    /// A random-noise JPEG — noise so JPEG cannot compress it away, leaving a
    /// payload of a few tens of megabytes. The cancel/restart step needs a download
    /// that is still transferring a moment after it starts; the solid-colour dummy
    /// photo above compresses to a few kilobytes and is gone instantly.
    ///
    /// Sized for the fastest link this runs on, not the slowest: the rig pulls tens
    /// of megabytes a second, and at 2600px the cold download measured barely over
    /// `minimumUsefulDownloadSeconds` — so the second, warmer fetch finished before
    /// the cancel could land and the step reported a product defect that was really
    /// a stopwatch problem.
    static func makeIncompressibleJPEG(pixelsPerSide: Int = 4200) throws -> Data {
        #if canImport(UIKit)
        let bytesPerRow = pixelsPerSide * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * pixelsPerSide)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            arc4random_buf(base, buffer.count)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: pixelsPerSide,
                                    height: pixelsPerSide,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 1.0) else {
            throw FlightCheckError.imageEncodingFailed
        }
        return data
        #else
        throw FlightCheckError.imageEncodingFailed
        #endif
    }
}
