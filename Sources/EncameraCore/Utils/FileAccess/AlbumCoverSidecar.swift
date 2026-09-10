import Foundation
import CryptoKit

/// Per-album synced cover image ID, captured from CloudKit's `EncAlbum.coverMediaRef`
/// during reconciliation so the thumbnail loading chain can resolve it offline.
///
/// A derived cache, like the size sidecar it sits beside: it lives in the local,
/// never-synced `MediaIndex` directory, is excluded from backup, and a loss costs
/// a re-sync rather than data. The file stores a single `mediaID` string and never
/// contains the album name.
public actor AlbumCoverSidecar {

    private struct Payload: Codable {
        var version: Int = 1
        var coverMediaID: String?
    }

    private let fileURL: URL
    private var cachedID: String?

    public static func sidecarURL(for album: Album) -> URL {
        let digest = SHA256.hash(data: Data(album.id.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return MediaIndexStore.indexDirectoryURL().appendingPathComponent("\(hash).enccover")
    }

    public init(album: Album) {
        self.init(fileURL: Self.sidecarURL(for: album))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            self.cachedID = decoded.coverMediaID
        } else {
            self.cachedID = nil
        }
    }

    public func coverMediaID() -> String? {
        cachedID
    }

    public func setCoverMediaID(_ id: String?) throws {
        let data = try JSONEncoder().encode(Payload(coverMediaID: id))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        excludeFromBackup()
        cachedID = id
    }

    private func excludeFromBackup() {
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
