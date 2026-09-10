//
//  AlbumDirectoryNaming.swift
//  EncameraCore
//

import Foundation

/// Which directory names at a storage root are albums.
///
/// Two naming schemes are in the wild and both are load-bearing:
///
/// - `Album_<base64>` — the album name encrypted with the album key
///   (`Album.encryptedPathComponent`). Everything created since name encryption.
/// - A plaintext album name — everything created before it. These are not
///   convertible: the directory name IS the album's identity, and `Album.id`
///   plus every name-derived `UserDefaults` key are built from it.
///
/// So an album directory cannot be recognized by a prefix. It is recognized by
/// elimination: any directory at the root that is not one of the known non-album
/// siblings. That is the rule the app shipped with before the `albums/`
/// subdirectory existed, and re-adopting it is what makes pre-encryption albums
/// visible again.
public enum AlbumDirectoryNaming {

    /// The directory holding albums, relative to a storage root.
    public static let albumsDirectory = "albums"

    /// Names at a storage root that are definitively not albums.
    ///
    /// Compared case-insensitively — `RevenueCat` has shipped under both casings,
    /// and the pre-`albums/` exclusion list carried each spelling separately.
    private static let reservedNames: Set<String> = [
        albumsDirectory,
        AppConstants.previewDirectory,
        "thumbs",
        "revenuecat",
        "inbox",          // created by iOS document interaction, never by us
        ".trash"
    ]

    /// Whether `name` is an album directory. Dot-prefixed names are always
    /// excluded: they are filesystem and iCloud bookkeeping, never albums. So is
    /// anything the RevenueCat SDK puts beside the albums: its current caches are
    /// named `<bundle id>.revenuecat.<purpose>` and appear as soon as the first
    /// purchases response lands, which can be before the directory migration runs
    /// on a launch that follows an erase.
    public static func isAlbumDirectoryName(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let lowercased = name.lowercased()
        guard !lowercased.contains(".revenuecat.") else { return false }
        return !reservedNames.contains(lowercased)
    }
}
