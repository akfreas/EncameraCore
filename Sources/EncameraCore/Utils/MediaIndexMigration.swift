//
//  MediaIndexMigration.swift
//  EncameraCore
//
//  One-time startup migration that builds the per-album media index for albums
//  that pre-date the pagination feature. Idempotent — albums that already have
//  an index are skipped.
//

import Foundation

public enum MediaIndexMigration {

    /// Builds missing indexes for every album. Safe to call on each launch:
    /// albums that already have an index are skipped, and if none need building
    /// no work is done.
    public static func run(albumManager: AlbumManaging) async {
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        let albumsNeedingIndex = albums.filter { !MediaIndexStore.hasIndex(for: $0) }
        guard !albumsNeedingIndex.isEmpty else {
            return
        }

        for album in albumsNeedingIndex {
            let access = await InteractableMediaFileAccess(for: album, albumManager: albumManager)
            await access.rebuildIndex()
        }
    }
}
