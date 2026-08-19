//
//  CloudKitAlbumsSync.swift
//  EncameraCore
//
//  App-level fan-out for CloudKit pushes: a per-album `CloudKitFileAccess` only
//  delta-syncs the album it was configured for, so inactive CloudKit albums (e.g.
//  while the album grid is shown) would never refresh on a push. This observes
//  `cloudKitZoneChanged` and reconciles every CloudKit album.
//

import Foundation

public actor CloudKitAlbumsSync: DebugPrintable {

    private let albumManager: AlbumManaging
    /// Builds the album-existence reconciler (chunk 13). Injectable so tests can
    /// supply a deterministic in-memory store; production uses the shared provider.
    private let makeReconciler: @Sendable (AlbumManaging) -> CloudKitAlbumReconciler
    /// Gates reconciliation on the launch-time credential wait having resolved.
    /// `CloudKitAlbumReconciler` matches synced keys against a one-way album-id
    /// hash, so running it while iCloud Keychain credentials are still in flight
    /// reports every remote album as "needs a key" and shows an empty grid. The
    /// key can appear mid-wait (`.restoringKeyMaterial` re-derives it), which
    /// fires `keyPublisher` and would otherwise start a sync early.
    private let isReadyToSync: @Sendable () -> Bool
    private var observer: NSObjectProtocol?
    private var keyLibraryObserver: NSObjectProtocol?

    /// The most recent count of remote albums that could not be materialized for lack
    /// of a synced key (key backup off). The UI reads this to prompt "N albums need
    /// key backup to appear here".
    public private(set) var albumsNeedingKey: Int = 0

    /// Single-flight: a CK push landing at the same moment as scene-active used to
    /// run two overlapping full reconciles (and race `albumsNeedingKey`, then a
    /// plain Int on an @unchecked Sendable class). Overlapping callers now join the
    /// in-flight run, like `CloudKitSyncCoordinator` — and, like the coordinator,
    /// a join flags `resyncRequested` so a push landing mid-run (possibly after
    /// `fetchAllAlbums`/`reconcile` already passed) is honored by one extra pass
    /// instead of silently dropped until the next trigger.
    private var activeSync: Task<Void, Never>?
    /// Internal (not private) so tests can observe that a joiner's request landed.
    private(set) var resyncRequested = false

    public init(albumManager: AlbumManaging,
                observeNotifications: Bool = true,
                isReadyToSync: @escaping @Sendable () -> Bool = { true },
                makeReconciler: (@Sendable (AlbumManaging) -> CloudKitAlbumReconciler)? = nil) {
        self.albumManager = albumManager
        self.isReadyToSync = isReadyToSync
        self.makeReconciler = makeReconciler ?? { albumManager in
            CloudKitAlbumReconciler(store: CloudKitStoreProvider.makeStore(""),
                                    keyManager: albumManager.keyManager,
                                    albumManager: albumManager)
        }
        if observeNotifications {
            observer = NotificationCenter.default.addObserver(
                forName: .cloudKitZoneChanged, object: nil, queue: nil
            ) { [weak self] _ in
                // Static form: this closure is non-isolated and escaping, so it
                // cannot touch the actor-isolated instance method.
                Self.printDebug("cloudKitZoneChanged received; scheduling syncAll")
                Task { await self?.syncAll() }
            }
            // A decrypt-only key added for locked media (ENC-99) can make albums
            // materializable that this reconciler last reported as locked out.
            // Nothing else re-triggers it: an added, non-current key never fires
            // `keyPublisher`, so without this the count stays stale until the
            // next push or scene-active.
            keyLibraryObserver = NotificationCenter.default.addObserver(
                forName: .keyLibraryDidGrow, object: nil, queue: nil
            ) { [weak self] _ in
                Self.printDebug("keyLibraryDidGrow received; scheduling syncAll")
                Task { await self?.syncAll() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let keyLibraryObserver { NotificationCenter.default.removeObserver(keyLibraryObserver) }
    }

    /// First reconcile album *existence* from CloudKit (materialize newly-discovered
    /// albums, remove ones deleted elsewhere, push local-only ones up), THEN reconcile each
    /// CloudKit album's media index — so a newly materialized album is included in the
    /// same pass. Local/iCloud-Drive albums are ignored throughout. Overlapping calls
    /// coalesce into the in-flight run.
    public func syncAll() async {
        if let active = activeSync {
            resyncRequested = true
            printDebug("syncAll join reason=syncInFlight resyncRequested=true")
            await active.value
            printDebug("syncAll join done")
            return
        }
        printDebug("syncAll start")
        let task = Task {
            // Cleared inside the task, in the same synchronous stretch as
            // drainSyncAll's final `resyncRequested` check — a joiner either sees
            // the task (its flag is honored by the loop) or starts a fresh sync.
            defer { activeSync = nil }
            await drainSyncAll()
        }
        activeSync = task
        await task.value
        printDebug("syncAll ok")
    }

    private func drainSyncAll() async {
        var pass = 0
        repeat {
            resyncRequested = false
            pass += 1
            printDebug("drainSyncAll pass=\(pass)")
            await performSyncAll()
        } while resyncRequested
        printDebug("drainSyncAll ok passes=\(pass)")
    }

    private func performSyncAll() async {
        // Defer everything until the launch credential wait resolves — see
        // `isReadyToSync`. A trigger that arrives during the wait is not lost:
        // `credentialsMayHaveChanged`/scene-active re-fire once it resolves.
        guard isReadyToSync() else {
            printDebug("performSyncAll skip reason=awaitingCredentialRestore")
            return
        }

        // Skip the container entirely when the CloudKit plane is inactive: flag off
        // AND no `.cloudKit` albums exist locally (albums from a previous flag-on
        // period keep syncing). Without this, every scene-active hits the live
        // container for the vast majority of users, and the reconciler's self-heal
        // push has no flag check of its own.
        let hasCloudKitAlbums = albumManager.fetchAlbumsFromSources(includingHidden: true)
            .contains { $0.storageOption == .cloudKit }
        let featureEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        guard featureEnabled || hasCloudKitAlbums else {
            printDebug("performSyncAll skip reason=cloudKitPlaneInactive featureEnabled=\(featureEnabled) hasCloudKitAlbums=\(hasCloudKitAlbums)")
            // Clear rather than leave standing: this is the only writer of the
            // reported count, so a count from a flag-on period would otherwise
            // keep the grid banner claiming N locked albums for the rest of the
            // process — about albums the reconciler is no longer even looking
            // for. The credential-wait skip above deliberately keeps its count:
            // that wait resolves and re-fires within the launch.
            albumsNeedingKey = 0
            await LockedAlbumsReporter.shared.report(lockedAlbumCount: 0)
            return
        }
        printDebug("performSyncAll start featureEnabled=\(featureEnabled) hasCloudKitAlbums=\(hasCloudKitAlbums)")

        albumsNeedingKey = await makeReconciler(albumManager).reconcileAlbums()
        printDebug("performSyncAll reconcileAlbums done albumsNeedingKey=\(albumsNeedingKey)")
        // Hand the count to the UI (ENC-99). Before this, locked albums were
        // silently absent from the grid — the user had albums they could not see
        // and was never told they existed.
        await LockedAlbumsReporter.shared.report(lockedAlbumCount: albumsNeedingKey)

        // Re-fetch: the reconciler may have materialized or removed albums.
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
            .filter { $0.storageOption == .cloudKit }
        printDebug("performSyncAll mediaReconcile start albumCount=\(albums.count)")
        for album in albums {
            let access = await CloudKitFileAccess(album: album, albumManager: albumManager)
            _ = await access.reconcile()
        }
        // Building those accesses registered a coordinator for every CloudKit
        // album — the uploader can now reach backlogs for albums the user has not
        // opened this launch. The scene-active kick races this method (it fires
        // before the coordinators exist), so kick again now that they do.
        await CloudKitUploader.shared.kick()
        printDebug("performSyncAll ok albumCount=\(albums.count) albumsNeedingKey=\(albumsNeedingKey)")
    }
}
