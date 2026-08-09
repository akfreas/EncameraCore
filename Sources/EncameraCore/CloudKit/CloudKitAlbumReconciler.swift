//
//  CloudKitAlbumReconciler.swift
//  EncameraCore
//
//  Makes CloudKit the authoritative, cross-device source of truth for which albums
//  exist (chunk 13). Two-way reconcile against the `EncAlbum` records in the zone:
//   - Pull: a remote album with no local materialization becomes a local discovery
//     marker (so it shows in the grid and gets its media reconciled); a tombstoned
//     remote album removes the local materialization.
//   - Push (self-heal): a local `.cloudKit` album with no remote record is uploaded,
//     so an `EncAlbum` save that failed while offline at create-time is recovered.
//
//  The album-id hash is one-way, so a fresh device recovers the plaintext name by
//  matching a synced album key against the hash (XChaCha20's MAC rejects wrong keys;
//  the keyed-hash equality is the authoritative confirmation), then decrypts the
//  name ciphertext. Albums whose key is not present on this device (key backup off)
//  cannot be materialized and are reported via the locked-out count.
//
//  `.local` albums are never touched here — only CloudKit albums have `EncAlbum`
//  records, so a pure-local album never appears on another device.
//

import Foundation

public final class CloudKitAlbumReconciler: @unchecked Sendable, DebugPrintable {

    private let store: CloudKitMediaStoring
    private let keyManager: KeyManager
    private let albumManager: AlbumManaging
    private let tombstoneQueue: CloudKitAlbumTombstoneQueue

    public init(store: CloudKitMediaStoring,
                keyManager: KeyManager,
                albumManager: AlbumManaging,
                tombstoneQueue: CloudKitAlbumTombstoneQueue = CloudKitAlbumTombstoneQueue()) {
        self.store = store
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.tombstoneQueue = tombstoneQueue
    }

    /// Reconcile album existence between CloudKit and the local filesystem markers.
    /// Returns the number of remote albums that could NOT be materialized for lack of
    /// a matching (synced) key — surfaced to the UI as "needs key backup".
    @discardableResult
    public func reconcileAlbums() async -> Int {
        printDebug("reconcileAlbums start")
        guard await store.accountAvailable() else {
            // Distinct from the fetch-failure return below: both return 0, but this
            // one means we never talked to the server at all.
            printDebug("reconcileAlbums skip reason=accountUnavailable")
            return 0
        }

        // 0. Drain pending local delete intents FIRST (durable tombstone queue):
        // a delete made offline or killed mid-flight must reach the server before
        // the pull below, or its still-live record would resurrect the album on
        // the very device that deleted it. Whatever fails to drain stays queued
        // and is excluded from materialization and self-heal push this pass.
        var pendingTombstones = tombstoneQueue.pending()
        printDebug("reconcileAlbums tombstoneDrain start pending=\(pendingTombstones.count)")
        for albumID in pendingTombstones.sorted() {
            do {
                try await store.tombstoneAlbum(albumID: albumID)
                tombstoneQueue.remove(albumID)
                pendingTombstones.remove(albumID)
                printDebug("reconcileAlbums tombstoneDrain ok albumID=\(albumID)")
            } catch {
                // Stays queued on purpose; log so a permanently-stuck delete intent
                // (which also suppresses materialization of that album) is visible.
                printDebug("reconcileAlbums tombstoneDrain FAILED albumID=\(albumID) error=\(error)")
            }
        }
        printDebug("reconcileAlbums tombstoneDrain done stillPending=\(pendingTombstones.count)")

        let remote: [CloudKitAlbumMetadata]
        do {
            remote = try await store.fetchAllAlbums()
            printDebug("reconcileAlbums fetchAllAlbums ok remoteCount=\(remote.count)")
        } catch {
            printDebug("reconcileAlbums fetchAllAlbums FAILED error=\(error)")
            return 0   // degrade quietly; the next push/scene-active retries
        }

        let keys: [PrivateKey]
        do {
            keys = try keyManager.storedKeys()
        } catch {
            // An empty key list makes every remote album look locked-out, so the
            // reason for the zero count must not be lost.
            printDebug("reconcileAlbums storedKeys FAILED error=\(error); proceeding with no keys")
            keys = []
        }
        var localByHash = localCloudKitAlbumsByHash()
        var remoteIDs = Set<String>()
        var lockedOut = 0
        var adopted = 0
        var deletedLocally = 0
        printDebug("reconcileAlbums state keys=\(keys.count) localCloudKitAlbums=\(localByHash.count) remote=\(remote.count)")

        // 1. Pull remote -> local.
        for record in remote {
            remoteIDs.insert(record.albumID)

            // A locally-deleted album whose tombstone hasn't been confirmed yet:
            // its remote record may still read as live — do NOT resurrect it.
            if pendingTombstones.contains(record.albumID) {
                printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=tombstonePending")
                continue
            }

            if record.deletedAt != nil {
                if let album = localByHash[record.albumID] {
                    // Route through the manager so observers get the delete
                    // broadcast, currentAlbum is fixed up, and synced-store /
                    // hidden-state entries are cleaned — the same four things
                    // a user-initiated delete does.
                    printDebug("reconcileAlbums pull delete albumID=\(record.albumID) deletedAt=\(String(describing: record.deletedAt))")
                    albumManager.delete(album: album)
                    localByHash[record.albumID] = nil
                    deletedLocally += 1
                } else {
                    printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=remoteTombstonedButNotLocal")
                }
                continue
            }

            if localByHash[record.albumID] != nil {
                printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=alreadyMaterialized")
                // Existing albums keep their local hidden state: `EncAlbum.isHidden`
                // is only written at create-time and on explicit toggles, and the
                // authoritative cross-device hidden sync is AlbumsSyncedStore.
                // Applying the record here un-hid albums on every scene-active.
                continue
            }

            guard let match = Self.match(record: record, keys: keys) else {
                lockedOut += 1   // key not on this device — cannot decrypt/materialize
                printDebug("reconcileAlbums pull MISS albumID=\(record.albumID) reason=noMatchingKey candidateKeys=\(keys.count)")
                //TODO: We have to surface this!
                continue
            }
            printDebug("reconcileAlbums pull adopt albumID=\(record.albumID) isHidden=\(record.isHidden) createdAt=\(record.createdAt)")
            albumManager.adoptCloudKitAlbum(name: match.name,
                                            key: match.key,
                                            createdAt: record.createdAt,
                                            isHidden: record.isHidden)
            adopted += 1
        }

        // 2. Push local-only -> remote (self-heal an offline create). Skip albums
        // whose tombstone is still pending — re-uploading them would undo the delete.
        var pushed = 0
        for (hash, album) in localByHash where !remoteIDs.contains(hash) && !pendingTombstones.contains(hash) {
            let upload = CloudKitAlbumUpload(albumID: hash,
                                             encName: album.encryptedPathComponent,
                                             createdAt: album.creationDate,
                                             isHidden: albumManager.isAlbumHidden(album),
                                             keyFingerprint: album.key.keychainLabel)
            printDebug("reconcileAlbums push start albumID=\(hash) isHidden=\(upload.isHidden)")
            do {
                try await store.saveAlbum(upload)
                pushed += 1
                printDebug("reconcileAlbums push ok albumID=\(hash)")
            } catch {
                // Self-heal is best-effort by design (the next pass retries), but a
                // persistently failing push means the album never appears on other
                // devices — so the error must not be discarded silently.
                printDebug("reconcileAlbums push FAILED albumID=\(hash) error=\(error)")
            }
        }

        printDebug("reconcileAlbums ok remote=\(remote.count) adopted=\(adopted) deletedLocally=\(deletedLocally) pushed=\(pushed) lockedOut=\(lockedOut) stillPendingTombstones=\(pendingTombstones.count)")
        return lockedOut
    }

    // MARK: - Matching

    /// Find the synced key that owns `record`: the album-name ciphertext decrypts
    /// under that key AND the keyed hash of the recovered name equals the record name
    /// (the album id). Pure + `internal` so it can be unit-tested directly.
    static func match(record: CloudKitAlbumMetadata, keys: [PrivateKey]) -> (name: String, key: PrivateKey)? {
        for key in keys {
            let name = Album.decryptAlbumName(record.encName, key: key)
            if SyncedStoreEncryptionHandler.keyedHash(name, keyBytes: key.keyBytes) == record.albumID {
                printDebug("match hit albumID=\(record.albumID)")
                return (name, key)
            }
        }
        // Never log the decryption candidates themselves — the recovered name is
        // user data. Only the hash and the number of keys tried are safe.
        printDebug("match MISS albumID=\(record.albumID) keysTried=\(keys.count)")
        return nil
    }

    // MARK: - Local materialization

    private func localCloudKitAlbumsByHash() -> [String: Album] {
        var byHash: [String: Album] = [:]
        var unhashable = 0
        for album in albumManager.fetchAlbumsFromSources(includingHidden: true)
            where album.storageOption == .cloudKit {
            if let hash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) {
                byHash[hash] = album
            } else {
                // An album we cannot hash is invisible to BOTH the pull match and the
                // self-heal push, so it silently never syncs — worth shouting about.
                unhashable += 1
            }
        }
        if unhashable > 0 {
            printDebug("localCloudKitAlbumsByHash WARNING unhashableAlbums=\(unhashable) hashed=\(byHash.count)")
        }
        printDebug("localCloudKitAlbumsByHash ok count=\(byHash.count)")
        return byHash
    }

}
