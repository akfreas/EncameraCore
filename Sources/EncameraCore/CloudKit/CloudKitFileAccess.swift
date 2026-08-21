//
//  CloudKitFileAccess.swift
//  EncameraCore
//
//  The CloudKit branch of the app's file access. Reuses the EXISTING crypto and
//  preview pipeline (`DiskFileAccess.createPreview`) unchanged — only the transport
//  differs (decision doc §6). Save encrypts with `SecretFileHandlerV2` (metadata-
//  bearing, so V2) then uploads; load lazily fetches the blob then decrypts with the
//  format-agnostic `SecretFileHandler`; enumeration comes from the coordinator's
//  synced `MediaIndexStore`; delete removes the record outright and the change
//  feed carries that to every other device.
//  `InteractableMediaFileAccess` routes here for `.cloudKit` albums behind the flag.
//
//  Reads MUST use `SecretFileHandler`, never `SecretFileHandlerV2` (ENC-135):
//  migration uploads the on-disk ciphertext verbatim, so a `.cloudKit` album can hold
//  V1-format blobs from a user's legacy library. `SecretFileHandlerV2` throws on V1;
//  `SecretFileHandler` sniffs the V2 magic and reads both, exactly as the local
//  `DiskFileAccess` read path does. What is stored stays byte-for-byte what was on
//  disk — the reader adapts to the data, the data is never rewritten to suit it.
//

import Foundation
import UIKit

/// Supplies the `CloudKitMediaStoring` implementation. Production returns the real
/// store; UI tests bind a deterministic in-memory mock via `UITestSupport`.
public enum CloudKitStoreProvider {
    /// `tokenNamespace` scopes the store's zone change-token cursor per album so
    /// albums don't clobber each other's sync position. Mocks may ignore it.
    nonisolated(unsafe) public static var makeStore: @Sendable (_ tokenNamespace: String) -> CloudKitMediaStoring = { namespace in
        CloudKitMediaStore(tokenNamespace: namespace)
    }
}

public actor CloudKitFileAccess: MediaBackend, DebugPrintable {

    private let album: Album
    private let albumIDHash: String
    private let keyBytes: [UInt8]
    /// The key library, for proving which key encrypted a blob before it is uploaded.
    private let keyManager: KeyManager
    private let store: CloudKitMediaStoring
    private let coordinator: CloudKitSyncCoordinator
    private let directoryModel: DataStorageModel
    private let indexStore: MediaIndexStore
    /// Reused solely for the existing preview-generation pipeline.
    private let previewAccess: DiskFileAccess
    /// Durable home for captures that have not reached CloudKit yet.
    private let uploadQueue: CloudKitUploadQueue
    private let uploader: CloudKitUploader
    /// Change tag the local thumbnail file was fetched for, so a remote re-upload
    /// (new tag) forces a refresh instead of showing stale content. Persisted as a
    /// sidecar next to the album's blob cache: the facade constructs a fresh
    /// instance on every album switch while the coordinator's tag map is shared
    /// via the registry, so a purely in-memory map would treat every revisit as a
    /// mismatch — deleting good previews and re-downloading every visible
    /// thumbnail (and, offline, leaving them blank).
    private var thumbnailTags: [String: String] = [:]
    private var thumbnailTagsLoaded = false

    private var thumbnailTagsURL: URL {
        directoryModel.baseURL.appendingPathComponent(".thumbtags.json")
    }

    private func loadThumbnailTagsIfNeeded() {
        guard !thumbnailTagsLoaded else { return }
        thumbnailTagsLoaded = true
        guard let data = try? Data(contentsOf: thumbnailTagsURL) else {
            // No sidecar is normal for a never-visited album; an unreadable one
            // means every thumbnail looks stale and gets re-downloaded.
            let exists = FileManager.default.fileExists(atPath: thumbnailTagsURL.path)
            printDebug("loadThumbnailTags \(exists ? "FAILED" : "skip") albumID=\(albumIDHash) reason=\(exists ? "sidecarUnreadable" : "noSidecar")")
            return
        }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            printDebug("loadThumbnailTags FAILED albumID=\(albumIDHash) reason=decodeError bytes=\(data.count); every thumbnail will be treated as stale")
            return
        }
        thumbnailTags = decoded
        printDebug("loadThumbnailTags ok albumID=\(albumIDHash) tags=\(decoded.count)")
    }

    private func setThumbnailTag(_ tag: String?, for id: String) {
        loadThumbnailTagsIfNeeded()
        thumbnailTags[id] = tag
        // Written only after a fetch attempt, so the album demonstrably exists —
        // creating the cache directory here cannot confuse `AlbumManager.create`'s
        // existence check (see `CloudKitStorageModel.baseURL`).
        guard let data = try? JSONEncoder().encode(thumbnailTags) else {
            printDebug("setThumbnailTag FAILED id=\(id) reason=encodeError tags=\(thumbnailTags.count)")
            return
        }
        do {
            try FileManager.default.createDirectory(at: directoryModel.baseURL, withIntermediateDirectories: true)
        } catch {
            printDebug("setThumbnailTag WARNING id=\(id) could not create album dir raw=\(error); attempting the write anyway")
        }
        do {
            try data.write(to: thumbnailTagsURL, options: .atomic)
        } catch {
            // A failed write means the tag map resets on relaunch and every
            // thumbnail in this album is re-fetched.
            printDebug("setThumbnailTag FAILED id=\(id) tag=\(tag ?? "nil") file=\(thumbnailTagsURL.lastPathComponent) raw=\(error)")
        }
    }

    public init(album: Album, albumManager: AlbumManaging, store: CloudKitMediaStoring? = nil) async {
        self.album = album
        self.keyBytes = album.key.keyBytes
        self.keyManager = albumManager.keyManager
        let albumIDHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) ?? album.id
        self.albumIDHash = albumIDHash
        let resolvedStore = store ?? CloudKitStoreProvider.makeStore(albumIDHash)
        self.store = resolvedStore
        self.directoryModel = CloudKitStorageModel(album: album)
        let index = MediaIndexStore(album: album)
        self.indexStore = index
        if store != nil {
            // Explicit store (tests): own coordinator + fresh cache + a throwaway
            // upload queue in a temp directory, so a test never writes into (or
            // reads from) the real holding folder. The coordinator is registered
            // in an equally isolated registry handed to the uploader — otherwise
            // the uploader would look in the SHARED registry, never find this
            // coordinator, and the queue could never drain in tests.
            let isolatedQueue = CloudKitUploadQueue(
                baseDir: FileManager.default.temporaryDirectory
                    .appendingPathComponent("CloudKitUploads-test-\(UUID().uuidString)", isDirectory: true)
            )
            self.uploadQueue = isolatedQueue
            let isolatedRegistry = CloudKitCoordinatorRegistry()
            self.coordinator = await isolatedRegistry.coordinator(forAlbumID: albumIDHash) {
                CloudKitSyncCoordinator(albumID: albumIDHash,
                                        store: resolvedStore,
                                        cache: CloudKitBlobCache(),
                                        indexStore: index,
                                        uploadQueue: isolatedQueue)
            }
            self.uploader = CloudKitUploader(queue: isolatedQueue, registry: isolatedRegistry)
        } else {
            // Production: share ONE coordinator per album so the active album and the
            // push fan-out keep the same in-memory state.
            self.uploadQueue = .shared
            self.uploader = .shared
            self.coordinator = await CloudKitCoordinatorRegistry.shared.coordinator(forAlbumID: albumIDHash) {
                CloudKitSyncCoordinator(albumID: albumIDHash,
                                        store: resolvedStore,
                                        cache: CloudKitBlobCache.shared,
                                        indexStore: index,
                                        uploadQueue: .shared)
            }
        }
        let preview = DiskFileAccess()
        await preview.configure(for: album, albumManager: albumManager)
        self.previewAccess = preview
    }

    // MARK: - Configure

    /// `MediaBackend` conformance. A `CloudKitFileAccess` is bound to its album at
    /// `init` (it derives `albumIDHash`, the store, and the coordinator there), so
    /// the facade constructs a fresh instance per album rather than re-pointing an
    /// existing one. This is a no-op kept only to satisfy the protocol; the warm-up
    /// is driven by `start()`, which the facade calls after construction.
    public func configure(for album: Album, albumManager: AlbumManaging) async {
        // Intentionally empty — see doc comment above.
    }

    // MARK: - Lifecycle

    /// Ensures the custom zone exists, registers the push subscription, and does an
    /// initial delta sync. Safe to call repeatedly; no-ops when the account is
    /// unavailable. Push-driven re-sync is handled app-wide by `CloudKitAlbumsSync`
    /// (which covers inactive albums too), not per-instance here.
    public func start() async {
        printDebug("start begin albumID=\(albumIDHash)")
        if await store.accountAvailable() {
            do {
                try await store.ensureZoneExists()   // routed through the store; mocks no-op
            } catch {
                // Swallowed by the original `try?`: without the zone every save
                // below fails, and the cause is otherwise invisible.
                printDebug("start ensureZoneExists FAILED albumID=\(albumIDHash) raw=\(error)")
            }
        } else {
            printDebug("start skip albumID=\(albumIDHash) reason=accountUnavailable — zone not ensured")
        }
        await coordinator.startObserving()
        // Opening an album is the moment its backlog becomes uploadable: the
        // uploader can only work through a coordinator that exists, and this is
        // where one is guaranteed to. Covers captures made in a previous launch
        // that never got their chance.
        await uploader.kick()
        do {
            try await coordinator.sync(albumID: albumIDHash)
            printDebug("start ok albumID=\(albumIDHash)")
        } catch {
            // Swallowed by the original `try?`: the album silently shows whatever
            // the last successful sync left in the index.
            printDebug("start initialSync FAILED albumID=\(albumIDHash) raw=\(error)")
        }
    }

    // MARK: - Save (encrypt then upload)

    public func save(media: InteractableMedia<CleartextMedia>,
                     metadata: EncryptedFileMetadata?,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        // The custom zone must exist before records target it — `start()` runs in a
        // detached task, so an early capture can't assume it finished. Idempotent.
        if await store.accountAvailable() {
            do {
                try await store.ensureZoneExists()
            } catch {
                printDebug("save ensureZoneExists FAILED albumID=\(albumIDHash) raw=\(error); continuing — the upload will surface the real error")
            }
        } else {
            printDebug("save WARNING albumID=\(albumIDHash) account unavailable at save time; zone not ensured")
        }
        printDebug("save start albumID=\(albumIDHash) components=\(media.underlyingMedia.count) mediaType=\(media.mediaType)")
        var encrypted: [EncryptedMedia] = []
        for item in media.underlyingMedia {
            try Task.checkCancellation()
            let encMedia = try await saveSingle(item, metadata: metadata, progress: progress)
            encrypted.append(encMedia)
        }
        guard !encrypted.isEmpty else {
            // A bare `nil` here is indistinguishable from a caller-side no-op.
            printDebug("save FAILED albumID=\(albumIDHash) — no components encrypted; returning nil")
            return nil
        }
        printDebug("save ok albumID=\(albumIDHash) components=\(encrypted.count)")
        return try InteractableMedia(underlyingMedia: encrypted)
    }

    /// A unique CloudKit record name per media component. Photo and video
    /// components of a Live Photo share `mediaID` but must be distinct records.
    static func componentRecordName(mediaID: String, type: MediaType) -> String {
        MediaRecordName.componentRecordName(mediaID: mediaID, type: type)
    }

    private func saveSingle(_ item: CleartextMedia,
                            metadata: EncryptedFileMetadata?,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> EncryptedMedia {
        let encURL = directoryModel.driveURLForMedia(withID: item.id, type: item.mediaType)
        try FileManager.default.createDirectory(at: directoryModel.baseURL, withIntermediateDirectories: true)

        // 1. Encrypt with the existing V2 handler — only ciphertext leaves the device.
        let handler = SecretFileHandlerV2(keyBytes: keyBytes, source: item, targetURL: encURL)
        _ = try await handler.encryptWithMetadata(metadata ?? EncryptedFileMetadata())

        // 2. Generate + persist the encrypted preview via the existing pipeline. Only
        // attach the thumbnail if the file actually exists — a failed preview must not
        // make the whole record's asset save fail.
        do {
            _ = try await previewAccess.createPreview(for: item)
        } catch {
            // Deliberately non-fatal (see above), but it means the record uploads
            // without an eager thumbnail and other devices show a blank cell.
            printDebug("saveSingle preview FAILED mediaID=\(item.id) mediaType=\(item.mediaType) raw=\(error)")
        }
        let previewURL = directoryModel.previewURLForMedia(withID: item.id)
        let thumbURL = FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : nil
        if thumbURL == nil {
            printDebug("saveSingle thumbnail WARNING mediaID=\(item.id) — no preview file on disk; uploading the record without an eager thumbnail")
        }

        // Must run before the queue moves the file into the holding folder: the stamp
        // has to be part of the bytes that reach CloudKit.
        let proven = try await CloudKitKeyStamp.stampAndProveKey(forCiphertextAt: encURL,
                                                                 keyManager: keyManager)

        // 3. Describe the record that will eventually be uploaded.
        let size = (try? FileManager.default.attributesOfItem(atPath: encURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size == 0 {
            // Size 0 usually means the ciphertext is missing or unreadable — the
            // upload would then carry a bogus sizeBytes into the index.
            printDebug("saveSingle size WARNING mediaID=\(item.id) mediaType=\(item.mediaType) sizeBytes=0 file=\(encURL.lastPathComponent)")
        }
        let upload = CloudKitMediaUpload(
            albumID: albumIDHash,
            mediaID: item.id,
            mediaType: item.mediaType,
            createdAt: metadata?.primaryDate ?? Date(),
            sizeBytes: size,
            encryptedFileURL: encURL,
            encryptedThumbURL: thumbURL,
            recordName: Self.componentRecordName(mediaID: item.id, type: item.mediaType),
            keyFingerprint: proven.fingerprint
        )
        // 4. Hand the ciphertext to the durable holding folder. This MOVES the
        // file out of the album's cache directory, which lives under
        // `Library/Caches` and can be reclaimed by iOS — not somewhere the only
        // copy of a photo may sit while it waits for CloudKit.
        //
        // A failure here is the one case that genuinely loses the capture, so it
        // propagates: the camera has nowhere to put the photo.
        let queued: CloudKitMediaUpload
        do {
            queued = try await uploadQueue.enqueue(upload)
        } catch {
            printDebug("saveSingle enqueue FAILED recordName=\(upload.recordName) mediaID=\(item.id) raw=\(error)")
            throw error
        }

        // 5. Put it in the album now. From here the photo is visible, openable
        // and durable regardless of what CloudKit does — the upload is a
        // background errand, not a precondition.
        try await coordinator.registerLocally(queued)

        // 6. Nudge the uploader. Fire-and-forget: the capture is already saved.
        await uploader.kick()

        printDebug("saveSingle ok mediaID=\(item.id) recordName=\(upload.recordName) state=queuedForUpload")
        return EncryptedMedia(source: .url(queued.encryptedFileURL), mediaType: item.mediaType, id: item.id)
    }

    // MARK: - Load (lazy fetch then decrypt)

    public func loadMedia(media: InteractableMedia<some MediaDescribing>,
                          progress: @escaping @Sendable (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> {
        var decrypted: [CleartextMedia] = []
        for item in media.underlyingMedia {
            try Task.checkCancellation()
            let local = try await ensureLocalCiphertext(id: item.id, type: item.mediaType, progress: progress)
            progress(.decrypting(progress: 0))
            let encMedia = EncryptedMedia(source: .url(local), mediaType: item.mediaType, id: item.id)
            // Format-agnostic handler: the blob may be V1 (migrated verbatim from a
            // legacy local album) or V2. See the file header (ENC-135).
            let cleartext: CleartextMedia
            if item.mediaType == .photo {
                let handler = SecretFileHandler(keyBytes: keyBytes, source: encMedia)
                cleartext = try await handler.decryptInMemory()
            } else {
                let target = URL.tempMediaDirectory.appendingPathComponent("\(item.id).\(item.mediaType.decryptedFileExtension)")
                let handler = SecretFileHandler(keyBytes: keyBytes, source: encMedia, targetURL: target)
                cleartext = try await handler.decryptToURL()
            }
            decrypted.append(cleartext)
        }
        progress(.loaded)
        return try InteractableMedia(underlyingMedia: decrypted)
    }

    public func loadMediaToURLs(media: InteractableMedia<EncryptedMedia>,
                                progress: @escaping @Sendable (FileLoadingStatus) -> Void) async throws -> [URL] {
        var urls: [URL] = []
        for item in media.underlyingMedia {
            try Task.checkCancellation()
            let local = try await ensureLocalCiphertext(id: item.id, type: item.mediaType, progress: progress)
            progress(.decrypting(progress: 0))
            let encMedia = EncryptedMedia(source: .url(local), mediaType: item.mediaType, id: item.id)
            let target = URL.tempMediaDirectory.appendingPathComponent("\(item.id).\(item.mediaType.decryptedFileExtension)")
            // Format-agnostic handler — the blob may be V1 or V2 (ENC-135).
            let handler = SecretFileHandler(keyBytes: keyBytes, source: encMedia, targetURL: target)
            let cleartext = try await handler.decryptToURL()
            if let url = cleartext.url { urls.append(url) }
        }
        progress(.loaded)
        return urls
    }

    /// Resolves the current encrypted blob for `id` via the coordinator's
    /// change-tag-aware cache: a server-side re-upload (new tag) invalidates the
    /// stale copy and refetches, so we never decrypt outdated content. We decrypt
    /// directly from the cache URL rather than keeping a separate untracked copy.
    private func ensureLocalCiphertext(id: String,
                                       type: MediaType,
                                       progress: @escaping @Sendable (FileLoadingStatus) -> Void) async throws -> URL {
        let recordName = Self.componentRecordName(mediaID: id, type: type)
        progress(.downloading(progress: 0))
        do {
            let url = try await coordinator.ensureBlobLocal(recordName: recordName, albumID: albumIDHash) { fraction in
                progress(.downloading(progress: fraction))
            }
            printDebug("ensureLocalCiphertext ok recordName=\(recordName) file=\(url.lastPathComponent)")
            return url
        } catch {
            printDebug("ensureLocalCiphertext FAILED recordName=\(recordName) albumID=\(albumIDHash) raw=\(error)")
            throw error
        }
    }

    /// Materializes every indexed component's ciphertext into `destination`'s
    /// file layout, downloading anything not resident in the blob cache, and
    /// verifies each copy byte-for-byte by size before counting it. Previews need
    /// no copying — they live in the storage-agnostic global thumbnail directory.
    ///
    /// Never mutates CloudKit: the caller (the CloudKit -> local move) deletes
    /// the remote copies only after this returns successfully, so any failure
    /// here leaves the album fully usable in CloudKit.
    /// Returns the number of components exported.
    @discardableResult
    public func exportCiphertext(to destination: DataStorageModel,
                                 onItemExported: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> Int {
        let items = await enumerate()
        let fileManager = FileManager.default
        var exported = 0
        let totalComponents = items.reduce(0) { $0 + $1.underlyingMedia.count }
        // Report the plan up front so a progress surface can show "0 of N" while
        // the first (possibly evicted, slow-to-download) component materializes.
        await onItemExported?(0, totalComponents)
        printDebug("exportCiphertext start albumID=\(albumIDHash) items=\(items.count) destination=\(destination.baseURL.lastPathComponent)")
        for media in items {
            for component in media.underlyingMedia {
                try Task.checkCancellation()
                let sourceURL = try await ensureLocalCiphertext(id: component.id, type: component.mediaType, progress: { _ in })
                let destURL = destination.driveURLForMedia(withID: component.id, type: component.mediaType)
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destURL)
                let sourceSize = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value
                let destSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value
                guard let sourceSize, let destSize, sourceSize == destSize, destSize > 0 else {
                    printDebug("exportCiphertext VERIFY FAILED id=\(component.id) sourceSize=\(sourceSize ?? -1) destSize=\(destSize ?? -1)")
                    throw CloudKitMediaStoreError.underlying(NSError(
                        domain: "CloudKitFileAccess", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "exported copy of \(component.id) failed size verification"]))
                }
                exported += 1
                await onItemExported?(exported, totalComponents)
            }
        }
        printDebug("exportCiphertext ok albumID=\(albumIDHash) exported=\(exported)")
        return exported
    }

    // MARK: - Previews

    public func loadMediaPreview(for media: InteractableMedia<some MediaDescribing>) async throws -> PreviewModel {
        let source = media.thumbnailSource!
        let previewURL = directoryModel.previewURLForMedia(withID: source.id)
        let recordName = Self.componentRecordName(mediaID: source.id, type: source.mediaType)
        let currentTag = await coordinator.currentChangeTag(recordName: recordName)
        loadThumbnailTagsIfNeeded()
        // Refetch the eager thumbnail if it's missing OR a KNOWN server tag differs
        // from the tag the local copy was fetched for (a remote re-upload). A nil
        // `currentTag` means "no newer tag observed yet" (fresh coordinator before
        // its first delta sync) — trust the local file, mirroring the blob cache.
        let stale = currentTag != nil && thumbnailTags[source.id] != currentTag
        let missing = !FileManager.default.fileExists(atPath: previewURL.path)
        if missing || stale {
            printDebug("loadMediaPreview refetch recordName=\(recordName) reason=\(missing ? "missingLocalFile" : "staleTag") localTag=\(thumbnailTags[source.id] ?? "nil") serverTag=\(currentTag ?? "nil")")
            try? FileManager.default.removeItem(at: previewURL)
            do {
                try await store.fetchThumbnail(recordName: recordName, to: previewURL)
                // Only record the tag on a SUCCESSFUL fetch — otherwise a failed fetch
                // would mark the (missing/partial) thumbnail as current and never retry.
                setThumbnailTag(currentTag, for: source.id)
                printDebug("loadMediaPreview thumbnail ok recordName=\(recordName) tag=\(currentTag ?? "nil")")
            } catch {
                // Swallowed so the preview pipeline still runs (offline, or the
                // asset is not up yet); the cleared tag forces a retry next time.
                printDebug("loadMediaPreview thumbnail FAILED recordName=\(recordName) raw=\(error) — tag cleared so the next load retries")
                setThumbnailTag(nil, for: source.id)
            }
        } else {
            printDebug("loadMediaPreview thumbnail hit recordName=\(recordName) source=localFile tag=\(currentTag ?? "nil")")
        }
        var preview = try await previewAccess.loadMediaPreview(for: source)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        var preview = try await previewAccess.createPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    // MARK: - Delete (hard delete + cross-device propagation)

    public func delete(media: [InteractableMedia<EncryptedMedia>]) async throws {
        for interactable in media {
            for item in interactable.underlyingMedia {
                let recordName = Self.componentRecordName(mediaID: item.id, type: item.mediaType)
                printDebug("delete start recordName=\(recordName) albumID=\(albumIDHash)")

                // Drop any durable copy still waiting to upload first, so a
                // delete cannot leave an orphan in the holding folder that the
                // uploader would later push to CloudKit — resurrecting the photo
                // the user just deleted.
                let wasPending = await uploadQueue.cancel(recordName: recordName)

                // A pending item skips the remote delete (nothing is up there)
                // but still gets the full local cleanup and the deletion marker —
                // see `remove`. Errors propagate: a swallowed failure here used to
                // leave the index entry behind as a permanent ghost.
                try await coordinator.remove(recordName: recordName, albumID: albumIDHash, wasPending: wasPending)
                let localURL = directoryModel.driveURLForMedia(withID: item.id, type: item.mediaType)
                do {
                    try FileManager.default.removeItem(at: localURL)
                    printDebug("delete ok recordName=\(recordName) localCopyRemoved=true")
                } catch {
                    // Usually just "no local copy on this device"; only interesting
                    // when the file is there and genuinely cannot be removed.
                    let existed = FileManager.default.fileExists(atPath: localURL.path)
                    printDebug("delete ok recordName=\(recordName) localCopyRemoved=false stillPresent=\(existed) raw=\(error)")
                }
            }
        }
    }

    /// Runs the background uploader until the queue has had a full chance to
    /// empty, and waits for it. The app itself relies on `kick()`s; this is for
    /// tests and for callers that must observe upload completion.
    public func drainUploads() async {
        await uploader.drainNow()
    }

    // MARK: - Enumeration (from the synced index, never the network)

    /// Brings the local index in sync with CloudKit (delta fetch).
    @discardableResult
    public func reconcile() async -> Bool {
        do {
            try await coordinator.sync(albumID: albumIDHash)
            printDebug("reconcile ok albumID=\(albumIDHash)")
            return true
        } catch {
            // The bare `false` collapses cancellation, offline, and real CloudKit
            // failures into one indistinguishable value at every call site.
            printDebug("reconcile FAILED albumID=\(albumIDHash) cancelled=\(error is CancellationError) raw=\(error)")
            return false
        }
    }

    /// Sorted/filtered metadata enumeration from the synced index (never the network).
    public func enumerateMediaWithMetadata(sortBy sortOption: MediaSortOption,
                                           filterBy filterOptions: MediaFilterOptions) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] {
        let index = await indexStore.current() ?? MediaIndex(entries: [])
        return index.sortedFilteredEntries(sortBy: sortOption, filterBy: filterOptions).compactMap { entry in
            guard let media = materialize(entry) else { return nil }
            return MediaWithMetadata(media: media,
                                     metadata: nil,
                                     dateTaken: entry.dateTaken,
                                     dateEncrypted: entry.dateEncrypted,
                                     mediaSubtype: MediaFilterOptions(rawValue: entry.subtypeRawValue))
        }
    }

    /// Removes every item in the album from CloudKit and from the index.
    public func deleteAllMedia() async throws {
        let all = await enumerate()
        guard !all.isEmpty else {
            printDebug("deleteAllMedia skip albumID=\(albumIDHash) reason=emptyAlbum")
            return
        }
        printDebug("deleteAllMedia start albumID=\(albumIDHash) items=\(all.count)")
        try await delete(media: all)
        printDebug("deleteAllMedia ok albumID=\(albumIDHash) items=\(all.count)")
    }

    public func enumerate() async -> [InteractableMedia<EncryptedMedia>] {
        let entries = (await indexStore.current())?.entries ?? []
        return entries.compactMap { materialize($0) }.sorted {
            guard let a = $0.timestamp, let b = $1.timestamp else { return false }
            return a > b
        }
    }

    /// `FileEnumerator` conformance. CloudKit only ever produces
    /// `InteractableMedia<EncryptedMedia>`; the generic cast keeps the facade from
    /// having to special-case the backend.
    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T: MediaDescribing {
        (await enumerate()) as? [InteractableMedia<T>] ?? []
    }

    public func totalStoredMediaCount() async -> Int {
        (await indexStore.current())?.entries.count ?? 0
    }

    private func materialize(_ entry: MediaIndexEntry) -> InteractableMedia<EncryptedMedia>? {
        var underlying: [EncryptedMedia] = []
        if entry.hasPhotoComponent {
            underlying.append(EncryptedMedia(source: .url(cacheURL(id: entry.id, type: .photo)), mediaType: .photo, id: entry.id))
        }
        if entry.hasVideoComponent {
            underlying.append(EncryptedMedia(source: .url(cacheURL(id: entry.id, type: .video)), mediaType: .video, id: entry.id))
        }
        guard !underlying.isEmpty else {
            printDebug("materialize MISS mediaID=\(entry.id) — index entry has neither a photo nor a video component")
            return nil
        }
        do {
            return try InteractableMedia(underlyingMedia: underlying)
        } catch {
            // Swallowed by the original `try?`: the item silently vanishes from
            // the gallery with no indication that it was ever in the index.
            printDebug("materialize FAILED mediaID=\(entry.id) components=\(underlying.count) raw=\(error)")
            return nil
        }
    }

    /// The on-disk path where a lazily-downloaded blob actually lands (the blob cache
    /// keys by record name). `EncryptedMedia.source` must point here — not at the
    /// `id.ext` path — so source-readers find the file after a download.
    private func cacheURL(id: String, type: MediaType) -> URL {
        directoryModel.baseURL.appendingPathComponent(Self.componentRecordName(mediaID: id, type: type))
    }

    // MARK: - Diagnostics (iCloud Flight Check)

    /// Drops the cached ciphertext for a component so the next `loadMedia` is forced
    /// to re-download it from CloudKit — proving the blob is durable server-side
    /// rather than being served from the copy the upload cached locally.
    public func evictCachedBlob(for id: String, type: MediaType) async throws {
        try await coordinator.evict(recordName: Self.componentRecordName(mediaID: id, type: type))
    }

    /// Whether the component's ciphertext is in the blob cache right now. The
    /// flight check's cancel probe asserts on this: a cancelled download that
    /// secretly ran to completion caches its blob, and that shows up here no
    /// matter how fast the link is.
    public func isBlobCached(for id: String, type: MediaType) async -> Bool {
        await coordinator.isBlobCached(recordName: Self.componentRecordName(mediaID: id, type: type))
    }

    /// Removes the local thumbnail copy + its cached change-tag so the next
    /// `loadMediaPreview` re-fetches the eager thumbnail asset from CloudKit.
    ///
    /// Throws when the file exists but could not be removed: the flight check
    /// depends on the eviction actually happening — a swallowed failure made the
    /// next load look like a successful refetch when nothing was re-downloaded.
    /// An already-absent thumbnail is a successful eviction, not an error.
    public func evictThumbnail(for id: String) throws {
        let url = directoryModel.previewURLForMedia(withID: id)
        setThumbnailTag(nil, for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            printDebug("evictThumbnail ok id=\(id) — no local thumbnail to remove")
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
            printDebug("evictThumbnail ok id=\(id) file=\(url.lastPathComponent)")
        } catch {
            printDebug("evictThumbnail FAILED id=\(id) file=\(url.lastPathComponent) stillPresent=\(FileManager.default.fileExists(atPath: url.path)) raw=\(error)")
            throw error
        }
    }
}

// MARK: - MediaBackend conformance

extension CloudKitFileAccess {

    /// `MediaBackend.reconcile`. CloudKit has no per-file scan, so `onProgress` is
    /// not applicable and is ignored — the index is brought current by the delta
    /// sync. A cancelled parent task lets the sync's own `CancellationError`
    /// propagate; `reconcile()` returns `false` in that case rather than retrying.
    @discardableResult
    public func reconcile(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)? = nil
    ) async -> Bool {
        await reconcile()
    }

    /// `MediaBackend.sourceURL`. CloudKit blobs land under the `id#type` blob-cache
    /// path, not `id.ext`, so source-readers find the file after a lazy download.
    public func sourceURL(id: String, type: MediaType) async -> URL {
        cacheURL(id: id, type: type)
    }

    /// `MediaBackend.mediaIndex`. The coordinator (sharing this same store) keeps
    /// the index current; the store owns the read-through cache and reload-on-newer
    /// behavior, so this is a thin pass-through.
    public func mediaIndex() async -> MediaIndex? {
        await indexStore.current()
    }

    /// `FileReader.loadLeadingThumbnail(coverImageId:)`. Resolves the album cover
    /// through the cloud preview-fetch path (the eager thumbnail asset), rather
    /// than reading a local file that a cloud album does not have.
    public func loadLeadingThumbnail(coverImageId: String?) async throws -> UIImage? {
        guard let coverImageId, coverImageId != "none" else { return nil }
        let media = EncryptedMedia(source: .url(cacheURL(id: coverImageId, type: .photo)),
                                   mediaType: .photo,
                                   id: coverImageId)
        let interactable = try InteractableMedia(underlyingMedia: [media])
        let preview = try await loadMediaPreview(for: interactable)
        guard let data = preview.thumbnailMedia.data else {
            printDebug("loadLeadingThumbnail MISS coverImageId=\(coverImageId) — preview carries no thumbnail data")
            return nil
        }
        guard let image = UIImage(data: data) else {
            printDebug("loadLeadingThumbnail MISS coverImageId=\(coverImageId) — thumbnail data is not decodable as an image, bytes=\(data.count)")
            return nil
        }
        return image
    }

    /// `FileWriter.setKeyUUIDForExistingFiles`. No-op for CloudKit: key-UUID xattrs
    /// are a local-disk concern. CloudKit blobs carry their key association via the
    /// record/metadata, so there is nothing to backfill.
    public func setKeyUUIDForExistingFiles() async throws {
        // Intentionally empty — see doc comment above.
    }

    /// Cross-album copy for CloudKit albums is a later chunk; fail loudly rather
    /// than silently no-op.
    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        throw CloudKitMediaStoreError.operationNotSupported("copy")
    }

    /// Cross-album move for CloudKit albums is a later chunk; fail loudly.
    public func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)? = nil) async throws {
        throw CloudKitMediaStoreError.operationNotSupported("move")
    }
}
