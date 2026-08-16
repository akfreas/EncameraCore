//
//  DataStorageModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation
import Combine

public protocol DataStorageModel: DebugPrintable {
    var baseURL: URL { get }
    var album: Album { get }
    static var thumbnailDirectory: URL { get }
    var storageType: StorageType { get }

    init(album: Album)
    func initializeDirectories() throws
    static var rootURL: URL { get }
    static var albumsURL: URL { get }
    static func enumerateAlbumsDirectory() -> [URL]
}

enum DataStorageModelError: Error {
    case noURLForiCloudDownload
    case couldNotCreateMedia
}

extension DataStorageModel {

    static func enumeratorForStorageDirectory(at url: URL, resourceKeys: Set<URLResourceKey> = [], fileExtensionFilter: [String]? = nil, exclude: [String] = [], onlyDirectories: Bool = false) -> [URL] {
        let driveUrl = url
        _ = driveUrl.startAccessingSecurityScopedResource()

        var directoryContents: [URL]
        do {
            directoryContents = try FileManager.default.contentsOfDirectory(at: driveUrl, includingPropertiesForKeys: Array(resourceKeys), options: [])
        } catch {
            driveUrl.stopAccessingSecurityScopedResource()
            // Album roots are created lazily by their first writer, so scanning one
            // that does not exist yet is routine — `fetchAlbumsFromSources()` does it
            // on every album broadcast. Logging it would drown out real failures.
            if !Self.isMissingDirectory(error) {
                print("Error while enumerating files \(driveUrl.path): \(error.localizedDescription)")
            }
            return []
        }

        driveUrl.stopAccessingSecurityScopedResource()

        let filteredContents = directoryContents.filter { url in
            // Exclude .Trash directory
            if url.lastPathComponent == ".Trash" {
                return false
            }

            // Apply user-defined exclusions
            for excludeString in exclude {
                if url.path.contains(excludeString) {
                    return false
                }
            }

            // Filter for directories only if required
            if onlyDirectories {
                let isDirectory: Bool
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                    isDirectory = resourceValues.isDirectory ?? false
                } catch {
                    print("Error reading resource values for \(url.path): \(error)")
                    return false
                }
                return isDirectory
            }

            return true
        }

        if let fileExtensionFilter = fileExtensionFilter {
            return filteredContents.filter({
                let components = $0.lastPathComponent.split(separator: ".")
                guard components.count > 1 else {
                    return false
                }

                // Account for .icloud final extension, just take the "middle" extension
                guard let fileExtension = components[safe: 1] else { return false }
                return fileExtensionFilter.contains(where: { $0.lowercased() == fileExtension })
            })
        }
        return filteredContents
    }


    /// Whether a filesystem error means the item simply does not exist.
    static func isMissingDirectory(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)
    }

    public static var albumsURL: URL {
        rootURL.appendingPathComponent("albums", isDirectory: true)
    }

    public static func enumerateAlbumsDirectory() -> [URL] {
        var results = enumeratorForStorageDirectory(
            at: albumsURL,
            onlyDirectories: true
        ).filter { $0.lastPathComponent.hasPrefix("Album_") }

        // Also check rootURL for albums that haven't been migrated yet
        // (e.g. partial migration failure leaves some albums at rootURL).
        let legacyResults = enumeratorForStorageDirectory(
            at: rootURL,
            onlyDirectories: true
        ).filter { $0.lastPathComponent.hasPrefix("Album_") }

        let migratedNames = Set(results.map { $0.lastPathComponent })
        for url in legacyResults where !migratedNames.contains(url.lastPathComponent) {
            results.append(url)
        }

        return results
    }

    public static var thumbnailDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let thumbnailDirectory = documentsDirectory.appendingPathComponent(AppConstants.previewDirectory, isDirectory: true)
        return thumbnailDirectory
    }
    
    /// Whether this album has already been migrated to CloudKit, i.e. its discovery
    /// marker exists. `finalizeMigrationToCloudKit` writes that marker last, so it is
    /// the signal that the source copy is drained and must not be revived. Always
    /// false for a `.cloudKit` model, which IS the destination.
    var hasMigratedToCloudKit: Bool {
        // `.icloud` only, deliberately. A `.local` directory is also created while a
        // CloudKit marker exists — that is exactly what `moveCloudKitAlbumToLocal`
        // does on the way back — so applying this to local storage blocks the
        // reverse move from creating its destination. (Caught by
        // `testMoveCloudKitAlbumToLocalReportsPhasesAndMonotonicCounts`.) The
        // local -> CloudKit twin-entry behaviour is older and separate; this is
        // scoped to the iCloud Drive resurrection it was written for.
        guard storageType == .icloud else { return false }
        let marker = CloudKitStorageModel.albumsURL
            .appendingPathComponent(Album.cloudKitTwin(of: album).encryptedPathComponent)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    public func initializeDirectories() throws {
        let directories = [
            Self.thumbnailDirectory.path,
            Self.albumsURL.path,
            URL.tempMediaDirectory.path,
            URL.tempRecordingDirectory.path,
            baseURL.path
        ]

        for directory in directories {
            if FileManager.default.fileExists(atPath: directory) == false {
                if directory == baseURL.path {
                    // Never RE-create the drained source directory of an album that
                    // has already moved to CloudKit.
                    //
                    // `DiskFileAccess.configure` initializes directories for any
                    // album it is pointed at, including a stale reference held by a
                    // view model that has not yet adopted the migrated twin. On the
                    // rig that resurrected the iCloud Drive directory seconds after
                    // a successful migration, and the empty directory made the album
                    // reappear in the grid a second time — one real CloudKit album
                    // and one phantom still claiming to be on iCloud Drive.
                    //
                    // Only creation is blocked, and only once the CloudKit marker
                    // exists (which finalize writes last), so an album mid-migration
                    // and an album that never migrated are both untouched.
                    if hasMigratedToCloudKit {
                        printDebug("refusing to re-create drained source directory storage=\(storageType.rawValue) dir=\(baseURL.lastPathComponent)")
                        continue
                    }
                    printDebug("creating album directory storage=\(storageType.rawValue) dir=\(baseURL.lastPathComponent)")
                }
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
        }
        
        // Ensure local files are included in device backups for transfer to new devices
        if storageType == .local {
            try ensureBackupInclusion()
        }
    }

    /// Ensures that files in the storage directory are included in device backups
    /// This makes local files transfer to new devices via iCloud Backup or iTunes backup
    public func ensureBackupInclusion() throws {
        let directories = [baseURL, Self.thumbnailDirectory]
        
        for var directory in directories {
            if FileManager.default.fileExists(atPath: directory.path) {
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = false // Explicitly include in backup
                try directory.setResourceValues(resourceValues)
            }
        }
    }

    func driveURLForMedia<T: MediaDescribing>(_ media: T) -> URL {
        return driveURLForMedia(withID: media.id, type: media.mediaType)
    }

    public func driveURLForMedia(withID id: String, type: MediaType) -> URL {
        let filename = "\(id).\(type.encryptedFileExtension)"
        return baseURL.appendingPathComponent(filename)
    }

    
    func previewURLForMedia<T: MediaDescribing>(_ media: T) -> URL {
        let thumbnailPath = Self.thumbnailDirectory.appendingPathComponent("\(media.id).\(MediaType.preview.encryptedFileExtension)")
        return thumbnailPath
    }

    func previewURLForMedia(withID id: String) -> URL {
        Self.previewURL(forMediaID: id)
    }

    /// Preview location without needing an album instance. Previews are keyed by
    /// media id and live in one storage-agnostic directory, so callers that only
    /// know the id — such as the upload queue draining a backlog — can find them.
    static func previewURL(forMediaID id: String) -> URL {
        Self.thumbnailDirectory.appendingPathComponent("\(id).\(MediaType.preview.encryptedFileExtension)")
    }

    func enumeratorForStorageDirectory(resourceKeys: Set<URLResourceKey> = [], fileExtensionFilter: [String]? = nil) -> [URL] {
        return Self.enumeratorForStorageDirectory(at: baseURL, resourceKeys: resourceKeys, fileExtensionFilter: fileExtensionFilter)
    }
    
    func enumeratePreviewFiles() -> [URL] {
        return Self.enumeratorForStorageDirectory(
            at: Self.thumbnailDirectory,
            fileExtensionFilter: [MediaType.preview.encryptedFileExtension]
        )
    }

    public func countOfFiles(matchingFileExtension: [String] = [MediaType.photo.encryptedFileExtension]) -> Int {
        let files = enumeratorForStorageDirectory(resourceKeys: Set(), fileExtensionFilter: matchingFileExtension)

        var uniqueFileNames = Set<String>()

        for file in files {
            let fileNameWithoutExtension = file.deletingPathExtension().lastPathComponent
            uniqueFileNames.insert(fileNameWithoutExtension)
        }

        return uniqueFileNames.count
    }

    public static func deletePreviewDirectory() throws {
        if FileManager.default.fileExists(atPath: thumbnailDirectory.path) == false {
            return
        }
        try FileManager.default.removeItem(at: thumbnailDirectory)
    }

    static func deleteAllFiles() throws {
        for url in enumeratorForStorageDirectory(at: Self.albumsURL) {
            do {
                try FileManager.default.removeItem(at: url)
                debugPrint("Deleted item at \(url)")
            } catch {
                debugPrint("Error deleting item at \(url): ", error)
            }
        }
    }
}
