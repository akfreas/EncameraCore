//  Created by Alexander Freas on 12.11.23.
//

import Foundation
import Combine

// MARK: - Album Errors

public enum AlbumError: Error, CustomStringConvertible {
    case albumNameError
    case albumExists
    case albumNotFoundAtSourceLocation
    case noCurrentKeySet
    /// iCloud Drive album storage is deprecated. Once the CloudKit feature flag is on,
    /// no new `.icloud` albums may be created or moved into — CloudKit is the only
    /// cloud-backed option going forward.
    case iCloudDriveDeprecated
    /// Moving an album to CloudKit is a resumable, long-running upload — it must go
    /// through `CloudKitMigrationManager`, never the synchronous `moveAlbum`.
    case migrationRequiredForCloudKit
    /// Moving a CloudKit album to another storage means downloading its blobs and
    /// cleaning up the remote records — `moveCloudKitAlbumToLocal`, never the
    /// synchronous `moveAlbum` (which would move raw record-named cache files
    /// into a layout that cannot read them, and leave a live cloud copy behind).
    case downloadRequiredFromCloudKit
    /// The CloudKit discovery marker could not be written after a migration — the
    /// album's bytes are safe in CloudKit but the album would be undiscoverable on
    /// this device, so finalize must fail (and be retried) rather than proceed.
    case cloudKitMarkerWriteFailed
    /// The pre-move index reconcile failed, so the local index may be stale or
    /// empty. The CloudKit -> local move enumerates every destructive step from
    /// that index, so proceeding would orphan any record it doesn't know about;
    /// the move aborts and the album stays fully usable in CloudKit.
    case cloudReconcileFailed

    public var description: String {
        switch self {
        case .albumNameError:
            return L10n.albumNameInvalid
        case .albumExists:
            return L10n.aKeyWithThisNameAlreadyExists
        case .albumNotFoundAtSourceLocation:
            return L10n.albumNotFoundAtSourceLocation
        case .noCurrentKeySet:
            return L10n.noKeyAvailable
        case .iCloudDriveDeprecated:
            return "iCloud Drive albums are no longer supported. Use CloudKit instead."
        case .migrationRequiredForCloudKit:
            return "Moving an album to iCloud must go through the migration flow."
        case .downloadRequiredFromCloudKit:
            return "Moving an album out of iCloud must go through the download flow."
        case .cloudKitMarkerWriteFailed:
            return "Could not finish moving the album — its files are safe in iCloud. Try again."
        case .cloudReconcileFailed:
            return "Could not check iCloud for the album's latest contents — nothing was moved. Try again."
        }
    }
}

public enum AlbumOperation {
    case selectedAlbumChanged(album: Album?)
    case albumsUpdated(albums: [Album])
    case albumMoved(album: Album)
    case albumDeleted(album: Album)
    case albumRenamed(album: Album)
    case albumCreated(album: Album)
}

public class AlbumManager: AlbumManaging, ObservableObject, DebugPrintable {

    public var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> {
        albumOperationSubject.eraseToAnyPublisher()
    }

    private var albumOperationSubject: PassthroughSubject<AlbumOperation, Never> = PassthroughSubject()

    @Published public var currentAlbum: Album? {
        didSet {
            albumOperationSubject.send(.selectedAlbumChanged(album: currentAlbum))
            UserDefaultUtils.set(currentAlbum?.id, forKey: .currentAlbumID)
        }
    }

    public var currentAlbumMediaCount: Int? {
        guard let currentAlbum else {
            return nil
        }
        return albumMediaCount(album: currentAlbum)
    }

    private var _defaultStorageForAlbum: StorageType {
        didSet {
            UserDefaultUtils.set(_defaultStorageForAlbum.rawValue, forKey: .defaultStorageLocation)
        }
    }

    public var defaultStorageForAlbum: StorageType {
        get {
            // iCloud Drive is deprecated. A `.icloud` default may still be persisted from
            // before the deprecation — never hand it back, or the picker-less
            // quick-create paths would attempt a deprecated album.
            if _defaultStorageForAlbum == .icloud {
                return .local
            }
            return _defaultStorageForAlbum
        }
        set {
            _defaultStorageForAlbum = newValue
        }
    }

    public private(set) var keyManager: KeyManager

    /// Resolves an album's key by decrypting its name, rather than by looking a key up
    /// under a name no key has ever carried. See `matchAlbumToKeyIfNeeded`.
    private lazy var keyDiscovery = KeyDiscovery(keyManager: keyManager)

    /// Albums found on disk whose key is not on this device, as of the last scan.
    ///
    /// They are deliberately absent from `fetchAlbumsFromSources` — an album cannot be
    /// shown, counted, or written to without the key that encrypted it — but dropping
    /// them silently would tell a user their photos are gone when the album is intact
    /// and only its key is missing.
    public private(set) var lockedAlbumCount: Int = 0

    /// The locked album placeholders collected during the last scan, carrying enough
    /// metadata to render a "Missing Key" tile in the album grid.
    public private(set) var lockedAlbums: [LockedAlbumPlaceholder] = []

    /// The synced data store for album settings (optional, uses legacy UserDefaults if nil)
    private var albumsSyncedStore: AlbumsSyncedStore?

    private var syncedStoreCancellables = Set<AnyCancellable>()

    /// Sets the hidden state for an album
    /// Uses synced store if available, falls back to legacy UserDefaults
    public func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album) {
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setAlbumHidden(album.name, isHidden: isAlbumHidden)
                removeLegacyHiddenKey(albumName: album.name)
            } catch {
                printDebug("Failed to use synced store, falling back to UserDefaults: \(error)")
                legacyDefaults.set(isAlbumHidden, forKey: Self.legacyHiddenKey(albumName: album.name))
            }
        } else {
            legacyDefaults.set(isAlbumHidden, forKey: Self.legacyHiddenKey(albumName: album.name))
        }
        pushCloudKitAlbumRecord(album)
        broadcastAlbumsUpdated()
    }

    /// Checks if an album is hidden
    /// Uses synced store if available, falls back to legacy UserDefaults
    public func isAlbumHidden(_ album: Album) -> Bool {
        if let syncedStore = albumsSyncedStore {
            do {
                let hidden = try syncedStore.isAlbumHidden(album.name)
                // If the synced store has a record, it's authoritative
                if try syncedStore.fetchAlbum(name: album.name) != nil {
                    return hidden
                }
                // No record yet — check legacy and migrate if found
                let legacyKey = Self.legacyHiddenKey(albumName: album.name)
                if legacyDefaults.object(forKey: legacyKey) != nil {
                    let legacyValue = legacyDefaults.bool(forKey: legacyKey)
                    try syncedStore.setAlbumHidden(album.name, isHidden: legacyValue)
                    removeLegacyHiddenKey(albumName: album.name)
                    return legacyValue
                }
                return false
            } catch {
                printDebug("Failed to read from synced store, falling back to UserDefaults: \(error)")
                return legacyDefaults.bool(forKey: Self.legacyHiddenKey(albumName: album.name))
            }
        }
        return legacyDefaults.bool(forKey: Self.legacyHiddenKey(albumName: album.name))
    }

    public func fetchAlbumsFromSources(includingHidden: Bool) -> [Album] {
        let fileManager = FileManager.default
        // Read once for the whole scan: resolving a name is a cheap AEAD op, but
        // `storedKeys()` is a full keychain query and this runs on every broadcast.
        let storedKeys = (try? keyManager.storedKeys()) ?? []
        var lockedPlaceholders: [LockedAlbumPlaceholder] = []
        let mapToAlbum: (URL, StorageType) -> Album? = { url, storageType in
            let directoryName = url.lastPathComponent
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let creationDate = attributes?[.creationDate] as? Date

            guard let creationDate else { return nil }
            let album = self.matchAlbumToKeyIfNeeded(albumName: directoryName,
                                                     storageType: storageType,
                                                     creationDate: creationDate,
                                                     storedKeys: storedKeys)
            if album == nil {
                lockedPlaceholders.append(LockedAlbumPlaceholder(
                    encryptedDirectoryName: directoryName,
                    storageOption: storageType,
                    creationDate: creationDate
                ))
            }
            return album
        }

        let localAlbums = LocalStorageModel.enumerateAlbumsDirectory()
            .compactMap { url -> Album? in
                return mapToAlbum(url, .local)
            }
        var iCloudAlbums: [Album] = []
        if DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) == .available {
            iCloudAlbums = iCloudStorageModel.enumerateAlbumsDirectory()
                .compactMap { url -> Album? in
                    return mapToAlbum(url, .icloud)
                }
        }
        // CloudKit albums keep a discovery marker under the CloudKit albums root (their
        // blobs live in CloudKit + a hashed cache). Scan unconditionally — the marker
        // only exists if a CloudKit album was created — so they appear in the grid and
        // get reconciled by the push fan-out.
        let cloudKitAlbums = CloudKitStorageModel.enumerateAlbumsDirectory()
            .compactMap { url -> Album? in
                return mapToAlbum(url, .cloudKit)
            }
        lockedAlbumCount = lockedPlaceholders.count
        lockedAlbums = lockedPlaceholders
        return Set(localAlbums)
            .union(Set(iCloudAlbums))
            .union(Set(cloudKitAlbums))
            .filter { includingHidden || !isAlbumHidden($0) }
            .sorted(by: { $0.creationDate < $1.creationDate })
    }

    public func restoreCurrentAlbumFromUserDefaults() {
        let albums = fetchAlbumsFromSources()
        if let currentAlbumID = UserDefaultUtils.string(forKey: .currentAlbumID),
           let foundAlbum = albums.first(where: { $0.id == currentAlbumID }) {
            currentAlbum = foundAlbum
        } else {
            currentAlbum = albums.first
        }
    }

    private func broadcastAlbumsUpdated() {
        albumOperationSubject.send(.albumsUpdated(albums: fetchAlbumsFromSources()))
    }

    public func notifyAlbumsChanged() {
        broadcastAlbumsUpdated()
    }

    /// Creates a new AlbumManager
    /// - Parameters:
    ///   - keyManager: The key manager for encryption operations
    ///   - syncedDataStore: Optional synced data store for iCloud sync (uses legacy UserDefaults if nil)
    required public init(keyManager: KeyManager, syncedDataStore: SyncedDataStore? = nil) {
        self.keyManager = keyManager

        // Initialize defaultStorageForAlbum first (before any callbacks can fire)
        if let defaultStorageLocationValue = UserDefaultUtils.string(forKey: .defaultStorageLocation),
           let defaultStorageLocation = StorageType(rawValue: defaultStorageLocationValue) {
            self._defaultStorageForAlbum = defaultStorageLocation
        } else {
            self._defaultStorageForAlbum = .local
        }

        // Set up synced store if provided (after all properties are initialized)
        if let syncedDataStore = syncedDataStore {
            self.albumsSyncedStore = AlbumsSyncedStore(store: syncedDataStore)

            // Subscribe to external changes
            albumsSyncedStore?.externalChangePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.broadcastAlbumsUpdated()
                    self.restoreCurrentAlbumFromUserDefaults()
                }
                .store(in: &syncedStoreCancellables)
        }

        restoreCurrentAlbumFromUserDefaults()
    }

    public func delete(album: Album) {
        let fileManager = FileManager.default
        let albumURL = album.storageURL

        // Check if the directory exists
        if fileManager.fileExists(atPath: albumURL.path) {
            // If the directory exists, delete it
            try? fileManager.removeItem(at: albumURL)
        }

        albumsSyncedStore?.deleteAlbum(name: album.name)
        removeLegacyHiddenKey(albumName: album.name)
        removeLegacyCoverImageKey(albumName: album.name)
        // CloudKit albums: also remove the discovery marker + synced index, and
        // delete the `EncAlbum` record so the deletion propagates to other devices
        // and its media cascade away with it. `.local` albums skip this entirely.
        if album.storageOption == .cloudKit {
            let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
            try? fileManager.removeItem(at: marker)
            try? fileManager.removeItem(at: MediaIndexStore.indexURL(for: album))
            deleteCloudKitAlbumRecord(album)
        }

        albumOperationSubject.send(.albumDeleted(album: album))
        broadcastAlbumsUpdated()
        currentAlbum = fetchAlbumsFromSources().first
    }

    // MARK: - CloudKit album record sync (chunk 13)

    /// Upsert the album's `EncAlbum` record so it syncs across devices. Fire-and-forget:
    /// the on-disk marker already makes the album usable locally, and
    /// `CloudKitAlbumReconciler` self-heals a failed/offline upload on the next sync.
    /// No-op for non-CloudKit albums and when CloudKit is unavailable (the store guards
    /// on account status, so the `try?` simply discards the unavailable error).
    ///
    /// Gated on the `cloudKitStorage` feature: `EncAlbum` records only matter when the
    /// CloudKit plane is active, and the gate keeps a real `CloudKitMediaStore` (which
    /// touches the live container) from being constructed in flag-off contexts.
    private func pushCloudKitAlbumRecord(_ album: Album) {
        guard FeatureToggle.isEnabled(feature: .cloudKitStorage),
              album.storageOption == .cloudKit,
              let hash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes),
              let albumFingerprint = CloudKitKeyStamp.provenAlbumFingerprint(for: album,
                                                                            keyManager: keyManager) else { return }
        let rawCover = getAlbumCoverImageId(album: album)
        let coverMediaID = (rawCover == nil || rawCover == "none") ? nil : rawCover
        let upload = CloudKitAlbumUpload(albumID: hash,
                                         encName: album.encryptedPathComponent,
                                         createdAt: album.creationDate,
                                         isHidden: isAlbumHidden(album),
                                         keyFingerprint: albumFingerprint,
                                         coverMediaID: coverMediaID)
        let store = CloudKitStoreProvider.makeStore(hash)
        Task {
            guard (try? await store.saveAlbum(upload)) != nil else { return }
            // Confirmed on the server, so a later absence means someone deleted it.
            CloudKitAlbumPublishRegistry().markPublished(hash)
        }
    }

    /// Delete the album's `EncAlbum` record (cross-device delete). The durable
    /// intent is persisted FIRST: a fire-and-forget call alone loses the delete when
    /// the device is offline or the app is killed before the task runs — and a live
    /// remote record with no local marker would then be re-materialized by the album
    /// reconciler, resurrecting the "deleted" album on this device and every other.
    /// The reconciler drains the queue and refuses to re-materialize pending albums
    /// until the delete is confirmed.
    ///
    /// The record's media parent to it with `.deleteSelf`, so this reclaims their
    /// blobs too — which the old soft delete never did, because `.deleteSelf`
    /// cascades on a real delete only.
    ///
    /// Deliberately NOT gated on the `cloudKitStorage` feature: a `.cloudKit` album
    /// only exists from a flag-on period, and `CloudKitAlbumsSync.performSyncAll`
    /// keeps reconciling such albums with the flag off — a flag gate here would let
    /// the reconciler resurrect a flag-off delete (nothing queued, record still
    /// live). Both paths share the same predicate: `.cloudKit` albums always sync.
    private func deleteCloudKitAlbumRecord(_ album: Album) {
        guard album.storageOption == .cloudKit,
              let hash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) else { return }
        let queue = CloudKitAlbumDeleteQueue()
        queue.enqueue(hash)
        let publishRegistry = CloudKitAlbumPublishRegistry()
        let store = CloudKitStoreProvider.makeStore(hash)
        Task {
            // Queue the chunked members' blob-zone reclaim BEFORE the album
            // record goes: the `.deleteSelf` cascade covers every `EncMedia` and
            // its assets, but chunk records live in a different zone with no
            // references, so nothing cascades to them. Once queued, any album's
            // next sync drains them (the cascaded `EncMedia` resolves as
            // already-gone and the chunks are deleted). If the membership query
            // fails, the album stays queued and the reconciler retries on its
            // next pass — the destructive erase's blob-zone wipe remains the
            // backstop.
            do {
                let members = try await store.fetchMetadata(albumID: hash, includeThumbnail: false)
                let mediaDeleteQueue = CloudKitMediaDeleteQueue()
                for meta in members where meta.chunkCount > 0 {
                    mediaDeleteQueue.enqueue(meta.recordName, chunkCount: meta.chunkCount)
                }
            } catch {
                Self.printDebug("deleteCloudKitAlbumRecord chunk enumeration FAILED albumID=\(hash) — chunked members' blob records may be orphaned until erase raw=\(error)")
                return
            }
            do {
                try await store.deleteAlbum(albumID: hash)
                queue.remove(hash)
                // Forget the publish mark too, so re-creating an album with this
                // name later reads as a fresh create rather than as one that was
                // published and has since vanished.
                publishRegistry.forget(hash)
            } catch {
                // Left queued — the album reconciler retries on its next pass.
            }
        }
    }

    /// `AlbumManaging.adoptCloudKitAlbum`: materialize an album the reconciler
    /// discovered in CloudKit through the manager, so observers receive the same
    /// broadcasts a locally created album produces (grid refresh, current-album
    /// consistency) instead of the marker appearing behind everyone's back.
    public func adoptCloudKitAlbum(name: String, key: PrivateKey, createdAt: Date, isHidden: Bool) {
        let album = Album(name: name, storageOption: .cloudKit, creationDate: createdAt, key: key)
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
        try? FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        if isAlbumHidden(album) != isHidden {
            setIsAlbumHidden(isHidden, album: album)
        }
        albumOperationSubject.send(.albumCreated(album: album))
        broadcastAlbumsUpdated()
        if currentAlbum == nil {
            currentAlbum = album
        }
    }

    public func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setCoverImageId(album.name, coverImageId: image.id)
                removeLegacyCoverImageKey(albumName: album.name)
                pushCloudKitAlbumRecord(album)
                return
            } catch {
                printDebug("Failed to set cover image in synced store: \(error)")
            }
        }
        legacyDefaults.set(image.id, forKey: Self.legacyCoverImageKey(albumName: album.name))
        pushCloudKitAlbumRecord(album)
    }

    public func removeAlbumCover(album: Album) {
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setCoverImageId(album.name, coverImageId: "none")
                removeLegacyCoverImageKey(albumName: album.name)
                pushCloudKitAlbumRecord(album)
                return
            } catch {
                printDebug("Failed to remove cover image in synced store: \(error)")
            }
        }
        legacyDefaults.set("none", forKey: Self.legacyCoverImageKey(albumName: album.name))
        pushCloudKitAlbumRecord(album)
    }

    public func resetAlbumCover(album: Album) {
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setCoverImageId(album.name, coverImageId: nil)
                removeLegacyCoverImageKey(albumName: album.name)
                pushCloudKitAlbumRecord(album)
                return
            } catch {
                printDebug("Failed to reset cover image in synced store: \(error)")
            }
        }
        legacyDefaults.removeObject(forKey: Self.legacyCoverImageKey(albumName: album.name))
        pushCloudKitAlbumRecord(album)
    }

    public func getAlbumCoverImageId(album: Album) -> String? {
        if let syncedStore = albumsSyncedStore {
            do {
                if let id = try syncedStore.getCoverImageId(album.name) {
                    return id
                }
                // Check legacy UserDefaults and migrate if found
                let legacyKey = Self.legacyCoverImageKey(albumName: album.name)
                if let legacyValue = legacyDefaults.string(forKey: legacyKey) {
                    try syncedStore.setCoverImageId(album.name, coverImageId: legacyValue)
                    removeLegacyCoverImageKey(albumName: album.name)
                    return legacyValue
                }
                return nil
            } catch {
                printDebug("Failed to read cover image from synced store: \(error)")
            }
        }
        return legacyDefaults.string(forKey: Self.legacyCoverImageKey(albumName: album.name))
    }

    public func isAlbumCoverImageDisabled(album: Album) -> Bool {
        return getAlbumCoverImageId(album: album) == "none"
    }

    // MARK: - Legacy key helpers

    private static func legacyCoverImageKey(albumName: String) -> String {
        "albumCoverImage(albumName: \"\(albumName)\")"
    }

    private static func legacyHiddenKey(albumName: String) -> String {
        "isAlbumHidden(name: \"\(albumName)\")"
    }

    private var legacyDefaults: UserDefaults {
        UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
    }

    private func removeLegacyCoverImageKey(albumName: String) {
        let key = Self.legacyCoverImageKey(albumName: albumName)
        legacyDefaults.removeObject(forKey: key)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }

    private func removeLegacyHiddenKey(albumName: String) {
        let key = Self.legacyHiddenKey(albumName: albumName)
        legacyDefaults.removeObject(forKey: key)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }

    @discardableResult public func create(name: String, storageOption: StorageType) throws -> Album  {
        // iCloud Drive album creation is deprecated. No new `.icloud` albums may be
        // created via any caller, in any build configuration (UI pickers already hide
        // the option via DataStorageAvailabilityUtil; this is the authoritative
        // backstop). Not gated on `cloudKitStorage`: the flag governs whether CloudKit
        // is offered, not whether iCloud Drive is deprecated.
        if storageOption == .icloud {
            throw AlbumError.iCloudDriveDeprecated
        }
        guard let currentKey = keyManager.currentKey else {
            throw AlbumError.noCurrentKeySet
        }

        if let existingAlbum = fetchAlbumsFromSources(includingHidden: true).first(where: { $0.name == name }) {
            return existingAlbum
        }

        let album = Album(name: name, storageOption: storageOption, creationDate: Date(), key: currentKey)
        printDebug("Starting album creation process")

        let fileManager = FileManager.default
        let albumURL = album.storageURL

        printDebug("File manager and album URL are set up")

        // Check if the directory already exists
        printDebug("Checking if the directory exists at path: \(albumURL.path)")
        if fileManager.fileExists(atPath: albumURL.path) {
            // If the directory exists, throw the albumExists error
            printDebug("Directory already exists, throwing albumExists error")
            throw AlbumError.albumExists
        }

        printDebug("Directory does not exist, proceeding to create it")

        // If the directory does not exist, create it
        try fileManager.createDirectory(
            at: albumURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // CloudKit albums store blobs in CloudKit + a hashed cache (not an `Album_*`
        // dir), so also write a discovery marker so the album appears in the grid and
        // survives relaunch. Then push the `EncAlbum` record so the album syncs to the
        // user's other devices (chunk 13). `.local` albums never do either — they stay
        // pure-local and never reach CloudKit.
        if storageOption == .cloudKit {
            let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
            try? fileManager.createDirectory(at: marker, withIntermediateDirectories: true)
            pushCloudKitAlbumRecord(album)
        }

        printDebug("Directory created successfully")
        printDebug("Broadcasting album creation")
        albumOperationSubject.send(.albumCreated(album: album))
        broadcastAlbumsUpdated()
        return album
    }

    
    public func moveAlbum(album: Album, toStorage: StorageType) throws -> Album {
        // Moving an album into iCloud Drive creates a new iCloud Drive album, which is
        // deprecated. This used to throw only under `#if DEBUG`, on the reasoning that
        // a missed call site should stay lenient in shipped builds — but leniency here
        // means the release build silently creates exactly the album the deprecation
        // exists to prevent, and then walks into `iCloudStorageModel.rootURL`, which
        // `fatalError`s with no ubiquity container. Throwing is the lenient option.
        if toStorage == .icloud {
            throw AlbumError.iCloudDriveDeprecated
        }
        // A CloudKit move is a resumable upload, never a synchronous file move — it has
        // no correct path here, so funnel every caller through the migration engine.
        if toStorage == .cloudKit {
            throw AlbumError.migrationRequiredForCloudKit
        }
        // The reverse is equally wrong here: this generic path would move raw
        // record-named blob-cache files into a layout that cannot read them, skip
        // anything evicted from the cache, and leave the discovery marker and the
        // live CloudKit records behind. Funnel through `moveCloudKitAlbumToLocal`.
        if album.storageOption == .cloudKit {
            throw AlbumError.downloadRequiredFromCloudKit
        }
        let fileManager = FileManager.default
        let currentStorage = album.storageOption.modelForType.init(album: album)
        // Deliberately does NOT touch key sync. Moving an album used to call
        // `backupKeychainToiCloud(backupEnabled: true)` here, silently pushing the
        // user's key to iCloud Keychain with no prompt and the error swallowed.
        // Enabling key sync is exclusively user-initiated (Settings toggle or the
        // onboarding opt-in); no storage operation may enable it as a side effect.
        printDebug("Starting the move process for album: \(album.name)")
        printDebug("Current storage URL: \(currentStorage.baseURL)")

        // Check the source before resolving the destination: resolving an iCloud
        // Drive URL requires a ubiquity container, so there is no reason to reach
        // for one on a move that cannot happen.
        guard fileManager.fileExists(atPath: currentStorage.baseURL.path) else {
            printDebug("Album not found at the source location.")
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        // `.local` is the only destination this generic path can still reach — `.icloud`
        // is deprecated and `.cloudKit` requires the migration engine, both rejected
        // above. Constructing the destination explicitly rather than via an `.icloud`
        // fallback keeps `iCloudStorageModel.rootURL`'s `fatalError` off this path.
        let newStorage: DataStorageModel = LocalStorageModel(album: album)
        printDebug("New storage URL: \(newStorage.baseURL)")

        // Ensure the destination directory exists
        if !fileManager.fileExists(atPath: newStorage.baseURL.path) {
            printDebug("Destination directory does not exist. Creating new directory.")
            try fileManager.createDirectory(at: newStorage.baseURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Move files individually to merge contents
        let enumerator = fileManager.enumerator(at: currentStorage.baseURL, includingPropertiesForKeys: nil)
        while let sourceURL = enumerator?.nextObject() as? URL {
            let destinationURL = newStorage.baseURL.appendingPathComponent(sourceURL.lastPathComponent)

            if fileManager.fileExists(atPath: destinationURL.path) {
                printDebug("File already exists at destination: \(destinationURL.path). Implementing merge logic.")
                // Implement your logic for handling duplicate files
            } else {
                printDebug("Moving file from \(sourceURL.path) to \(destinationURL.path)")
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        // Delete the source directory if it's empty
        if let contents = try? fileManager.contentsOfDirectory(atPath: currentStorage.baseURL.path), contents.isEmpty {
            printDebug("Source directory is empty after moving files. Deleting source directory.")
            try fileManager.removeItem(at: currentStorage.baseURL)
        }

        // Update the album's storage option and URL if needed
        var movedAlbum = album
        movedAlbum.storageOption = toStorage
        albumOperationSubject.send(.albumMoved(album: movedAlbum))
        broadcastAlbumsUpdated()
        printDebug("Completed the move process for album: \(album.name)")
        return movedAlbum
    }

    /// Completes a resumable local/iCloud -> CloudKit migration by flipping the
    /// album's storage *identity* (the bytes are already in CloudKit + its on-device
    /// cache; the migration engine uploaded and deleted every file). Writes the
    /// CloudKit discovery marker so the album is found as a CloudKit album, drops the
    /// drained source directory so it isn't also discovered as an empty source-storage
    /// album, and broadcasts the change so the grid refreshes.
    @discardableResult
    public func finalizeMigrationToCloudKit(album: Album) throws -> Album {
        let cloudKitAlbum = Album.cloudKitTwin(of: album)

        // The marker is the ONLY way this device discovers a CloudKit album — if it
        // can't be written, the migrated album would vanish from the grid with all
        // its bytes safe but unreachable. Verify it exists before reporting success;
        // the caller keeps the migration checkpoint on failure so finalize retries.
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(cloudKitAlbum.encryptedPathComponent)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw AlbumError.cloudKitMarkerWriteFailed
        }
        // Push the album record so the migrated album appears on the user's other devices.
        pushCloudKitAlbumRecord(cloudKitAlbum)

        // Only drop the source dir if the engine drained it; a non-enumerated leftover
        // file is preserved rather than destroyed (no last-copy data loss).
        if album.storageOption != .cloudKit {
            let sourceModel = album.storageOption.modelForType.init(album: album)
            Album.removeDrainedSourceDirectory(at: sourceModel.baseURL)
        }

        if currentAlbum?.id == album.id { currentAlbum = cloudKitAlbum }
        albumOperationSubject.send(.albumMoved(album: cloudKitAlbum))
        broadcastAlbumsUpdated()
        return cloudKitAlbum
    }

    /// Moves a CloudKit album's contents back to local storage — the reverse of the
    /// migration engine, in one sitting: materialize every ciphertext locally
    /// (downloading anything evicted from the blob cache), verify the copies, and
    /// only THEN remove the cloud plane (media records, album record, discovery
    /// marker, blob cache, stale indexes). Any failure before the verification
    /// point leaves the album fully usable in CloudKit; a move is not a copy, so a
    /// completed move leaves no live remote records to rematerialize elsewhere.
    public func moveCloudKitAlbumToLocal(album: Album) async throws -> Album {
        try await moveCloudKitAlbumToLocal(album: album, onProgress: nil)
    }

    public func moveCloudKitAlbumToLocal(album: Album,
                                         onProgress: (@Sendable (CloudToLocalMoveProgress) async -> Void)?) async throws -> Album {
        guard album.storageOption == .cloudKit else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }
        var localAlbum = album
        localAlbum.storageOption = .local
        let localModel = LocalStorageModel(album: localAlbum)
        try localModel.initializeDirectories()

        await onProgress?(CloudToLocalMoveProgress(phase: .preparing, exportedCount: 0, totalCount: 0))
        let access = await CloudKitFileAccess(album: album, albumManager: self)
        // Bring the index current first so a record uploaded from another device
        // moments ago is included rather than silently left in the cloud. A FAILED
        // reconcile must abort: every destructive step below enumerates from the
        // local index, so a stale/empty index (fresh device, transient CloudKit
        // error) would export nothing yet still delete the album — orphaning
        // every un-indexed record on every device.
        guard await access.reconcile() else {
            throw AlbumError.cloudReconcileFailed
        }
        let exported = try await access.exportCiphertext(to: localModel) { exportedCount, totalCount in
            await onProgress?(CloudToLocalMoveProgress(phase: .downloading,
                                                       exportedCount: exportedCount,
                                                       totalCount: totalCount))
        }
        printDebug("moveCloudKitAlbumToLocal exported=\(exported) album=\(album.name)")

        // The point of no return. A cancel that arrives during the export aborts
        // cleanly here (local copies are just redundant bytes; the album is still
        // whole in CloudKit) — but past this check the cloud plane starts coming
        // down, and aborting mid-teardown would strand deleted records while
        // the album still reads as CloudKit.
        try Task.checkCancellation()

        // Local copies are verified — now remove the cloud plane. Media first
        // (each delete is awaited), then the album record. The album delete is ALSO
        // awaited (not fire-and-forget like delete): the durable retry queue is
        // device-local, so relying on it here would let a fresh install
        // rematerialize the album before this device retries.
        await onProgress?(CloudToLocalMoveProgress(phase: .removingRemoteCopy,
                                                   exportedCount: exported,
                                                   totalCount: exported))
        try await access.deleteAllMedia()
        if let hash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) {
            let queue = CloudKitAlbumDeleteQueue()
            queue.enqueue(hash)
            do {
                try await CloudKitStoreProvider.makeStore(hash).deleteAlbum(albumID: hash)
                queue.remove(hash)
                // The record name is free again, so a later move back to iCloud is
                // an ordinary create rather than a collision with a leftover record.
                CloudKitAlbumPublishRegistry().forget(hash)
            } catch {
                // Left queued — the reconciler retries from this device. The local
                // move still completes; the worst interim state elsewhere is an
                // empty album, never data loss.
                printDebug("moveCloudKitAlbumToLocal album delete FAILED album=\(album.name) — left queued for retry raw=\(error)")
            }
        }

        // Drop the CloudKit identity on this device: discovery marker, blob cache
        // dir, the cloud album's index, and any stale index under the local
        // identity (the disk scan rebuilds it from the exported files).
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: localAlbum))

        if currentAlbum?.id == album.id { currentAlbum = localAlbum }
        albumOperationSubject.send(.albumMoved(album: localAlbum))
        broadcastAlbumsUpdated()
        printDebug("moveCloudKitAlbumToLocal completed album=\(album.name) items=\(exported)")
        return localAlbum
    }

    public func renameAlbum(album: Album, to newName: String) throws -> Album {
        // Validate the new name
        try validateAlbumName(name: newName)

        let existingAlbums = fetchAlbumsFromSources(includingHidden: true)

        // Check if an album with the new name already exists
        if existingAlbums.contains(where: { $0.name == newName }) {
            throw AlbumError.albumExists
        }
        guard var albumToUpdate = existingAlbums.first(where: { $0.id == album.id }) else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        albumToUpdate.name = newName
        // Rename the album in the file system
        let fileManager = FileManager.default
        let oldURL = album.storageURL
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(albumToUpdate.encryptedPathComponent)

        if fileManager.fileExists(atPath: oldURL.path) {
            try fileManager.moveItem(at: oldURL, to: newURL)
        } else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        albumOperationSubject.send(.albumRenamed(album: albumToUpdate))
        broadcastAlbumsUpdated()
        if currentAlbum?.id == album.id {
            currentAlbum = albumToUpdate
        }
        return albumToUpdate
    }



    public func storageModel(for album: Album) -> DataStorageModel? {
        album.storageOption.modelForType.init(album: album)
    }

    public func validateAlbumName(name: String) throws {
        guard name.count > 0 else {
            throw KeyManagerError.keyNameError
        }
    }

    public func albumMediaCount(album: Album) -> Int {
        // CloudKit albums keep membership in the synced index, not as on-disk files —
        // a directory scan would report 0 on a metadata-only device.
        if album.storageOption == .cloudKit {
            return MediaIndexStore.entryCount(for: album)
        }
        let storageModel = storageModel(for: album)
        return storageModel?.countOfFiles(matchingFileExtension: [MediaType.photo.encryptedFileExtension, MediaType.video.encryptedFileExtension]) ?? 0
    }

    /// Builds the album a directory represents, keyed by the key that actually
    /// encrypted it.
    ///
    /// The directory name IS the album's name encrypted with the album's own key, so
    /// the key is recoverable from it by trying candidates and keeping the one that
    /// authenticates. Names cannot identify a key here: every key is named
    /// `encamera_default_key`.
    ///
    /// A locked album returns nil rather than taking the current key. `Album.key` feeds
    /// the album's name, its identity, its media index and its CloudKit hash, so
    /// attaching a key that cannot read it does not degrade gracefully — it produces an
    /// album that is a different album, and writes new media under a key the rest of
    /// its contents do not share.
    private func matchAlbumToKeyIfNeeded(albumName: String,
                                         storageType: StorageType,
                                         creationDate: Date,
                                         storedKeys: [PrivateKey]) -> Album? {
        switch keyDiscovery.key(forEncryptedAlbumName: albumName, storedKeysSnapshot: storedKeys) {
        case .resolved(let key):
            return Album(encryptedName: albumName, storageOption: storageType, creationDate: creationDate, key: key)
        case .notProvable:
            // A legacy plaintext directory name, which no key encrypted. The current
            // key is as good an answer as exists, and is what shipped.
            guard let key = keyManager.currentKey else { return nil }
            return Album(encryptedName: albumName, storageOption: storageType, creationDate: creationDate, key: key)
        case .noKnownKey:
            return nil
        }
    }
}
