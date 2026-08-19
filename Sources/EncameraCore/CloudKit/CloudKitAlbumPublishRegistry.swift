//
//  CloudKitAlbumPublishRegistry.swift
//  EncameraCore
//
//  Which albums this device has seen confirmed on the server.
//
//  This is what lets the reconciler read "my album has no remote record" without
//  guessing. That sentence has two possible causes and they demand opposite
//  actions:
//
//    - never confirmed  -> the create never reached CloudKit (offline at
//                          create-time, or a failed save). Push it.
//    - confirmed before -> someone deleted it on another device. Remove it.
//
//  Answering that from LOCAL state is the point. The server cannot answer it: an
//  absent record looks identical either way, and a `CKQuery` cannot even be
//  trusted to report a record that does exist, because its index is eventually
//  consistent. Reaching for a server-side tombstone to break the tie is what put
//  a soft-delete on `EncAlbum` in the first place — a record that then never got
//  cleaned up, kept its media alive, and resurrected "deleted" photos whenever an
//  album with the same name was re-created.
//

import Foundation

public struct CloudKitAlbumPublishRegistry: DebugPrintable {

    private static let storageKey = "cloudkit_published_albums_v1"
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard) {
        self.defaults = defaults
    }

    /// Album-id hashes this device has seen exist on the server.
    public func published() -> Set<String> {
        Self.lock.withLock { read() }
    }

    public func isPublished(_ albumID: String) -> Bool {
        Self.lock.withLock { read().contains(albumID) }
    }

    /// Record that the server confirmed this album — after a successful save, or on
    /// adopting a record the feed reported.
    public func markPublished(_ albumID: String) {
        Self.lock.withLock {
            var set = read()
            guard set.insert(albumID).inserted else { return }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("markPublished ok albumID=\(albumID) published=\(set.count)")
        }
    }

    /// Forget the album entirely, so a later re-create is treated as new rather than
    /// as something that once existed and has since been deleted.
    public func forget(_ albumID: String) {
        Self.lock.withLock {
            var set = read()
            guard set.remove(albumID) != nil else { return }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("forget ok albumID=\(albumID) published=\(set.count)")
        }
    }

    private func read() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }
}
