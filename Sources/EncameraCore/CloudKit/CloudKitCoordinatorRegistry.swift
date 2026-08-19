//
//  CloudKitCoordinatorRegistry.swift
//  EncameraCore
//
//  One `CloudKitSyncCoordinator` per album id, shared across the active album's
//  `CloudKitFileAccess` and the push fan-out (`CloudKitAlbumsSync`). Without this,
//  the fan-out would build ephemeral coordinators that update the on-disk index but
//  not the live coordinator's in-memory `changeTags`/`deletedRecordNames`, so the
//  active instance could serve stale blobs or miss cross-device deletes.
//

import Foundation

public actor CloudKitCoordinatorRegistry: DebugPrintable {

    public static let shared = CloudKitCoordinatorRegistry()

    private var coordinators: [String: CloudKitSyncCoordinator] = [:]

    public init() {}

    /// The coordinator for `albumID`, creating it via `make` on first request and
    /// reusing the same instance thereafter.
    public func coordinator(forAlbumID albumID: String,
                            make: () -> CloudKitSyncCoordinator) -> CloudKitSyncCoordinator {
        if let existing = coordinators[albumID] {
            printDebug("coordinator hit albumID=\(albumID) registrySize=\(coordinators.count)")
            return existing
        }
        // A miss means a brand-new coordinator with empty in-memory changeTags /
        // deletedRecordNames; an unexpected miss for an active album is exactly the
        // stale-blob bug this registry exists to prevent.
        let created = make()
        coordinators[albumID] = created
        printDebug("coordinator MISS albumID=\(albumID) created registrySize=\(coordinators.count)")
        return created
    }

    /// The coordinator for `albumID` only if one already exists — never creates.
    ///
    /// Building a coordinator needs the album's key (for its `MediaIndexStore`),
    /// which the upload queue deliberately does not persist. So the uploader asks
    /// for what is already here; anything for an album that has not been opened
    /// this launch drains when it is.
    public func existingCoordinator(forAlbumID albumID: String) -> CloudKitSyncCoordinator? {
        coordinators[albumID]
    }

    /// Album ids with a live coordinator, for callers that want to drain
    /// everything currently reachable.
    public func knownAlbumIDs() -> [String] {
        Array(coordinators.keys)
    }
}
