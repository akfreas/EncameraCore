//
//  FileProtocols.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine
import UIKit

public enum FileAccessError: Error, ErrorDescribable {
    case missingDirectoryModel
    case missingPrivateKey
    case missingKeyManager
    case unhandledMediaType
    case couldNotLoadMedia
    case iCloudFileNotDownloaded(status: iCloudFileStatus)
    case iCloudDownloadFailed(status: iCloudFileStatus)
    case iCloudDownloadInProgress(status: iCloudFileStatus)
    case iCloudDownloadTimeout
    /// The media is intact but no key in this device's library authenticates it
    /// (ENC-99). Distinct from `missingPrivateKey`, which means this device has
    /// no key at all, and from a decrypt failure, which means damaged bytes.
    ///
    /// `requiredStampPrefix` is the file's own stamp when it carries one; nil
    /// means the required key is genuinely unknown and must not be named.
    case missingKeyForMedia(requiredStampPrefix: UInt32?)
    /// Asked to evict a local copy that is the only copy — a purely local album.
    /// Honouring it would destroy the media, so it is refused rather than treated
    /// as a no-op that reports success.
    case localCopyNotEvictable

    /// The short `54E0-7B52` label for the key this media needs, when known.
    public var requiredKeyLabel: String? {
        guard case .missingKeyForMedia(let prefix) = self, let prefix else {
            return nil
        }
        return KeyFingerprint.displayLabel(stampPrefix: prefix)
    }

    public var displayDescription: String {
        switch self {
        case .missingKeyForMedia:
            if let label = requiredKeyLabel {
                return L10n.MissingKey.subtitleWithFingerprint(label)
            }
            return L10n.MissingKey.subtitleUnknown
        case .missingDirectoryModel:
            return "Missing directory model"
        case .missingPrivateKey:
            return L10n.noKeyAvailable
        case .missingKeyManager:
            return "Missing key manager"
        case .unhandledMediaType:
            return "Unhandled media type"
        case .couldNotLoadMedia:
            return "Could not load media"
        case .iCloudFileNotDownloaded(let status):
            return iCloudFileStatusUtil.userFriendlyErrorMessage(for: status)
        case .iCloudDownloadFailed(let status):
            return iCloudFileStatusUtil.userFriendlyErrorMessage(for: status)
        case .iCloudDownloadInProgress(let status):
            return iCloudFileStatusUtil.userFriendlyErrorMessage(for: status)
        case .iCloudDownloadTimeout:
            return L10n.ICloudError.downloadTimeout
        case .localCopyNotEvictable:
            return L10n.MediaInfo.evictUnavailableLocalOnly
        }
    }
}

public enum FileLoadingStatus {
    case notLoaded
    case downloading(progress: Double)
    case decrypting(progress: Double)
    case loaded
}

// MARK: - Sorting & Filtering Types

/// Sort options for media enumeration
public enum MediaSortOption: Sendable {
    case dateTaken(ascending: Bool)
    case dateEncrypted(ascending: Bool)
}

/// String-backed serialization so the chosen sort order can be persisted.
extension MediaSortOption: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "dateTaken_ascending": self = .dateTaken(ascending: true)
        case "dateTaken_descending": self = .dateTaken(ascending: false)
        case "dateEncrypted_ascending": self = .dateEncrypted(ascending: true)
        case "dateEncrypted_descending": self = .dateEncrypted(ascending: false)
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .dateTaken(let ascending):
            return ascending ? "dateTaken_ascending" : "dateTaken_descending"
        case .dateEncrypted(let ascending):
            return ascending ? "dateEncrypted_ascending" : "dateEncrypted_descending"
        }
    }
}

/// Filter options for media subtypes (OptionSet for multi-select)
public struct MediaFilterOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    
    public static let video = MediaFilterOptions(rawValue: 1 << 0)
    public static let livePhoto = MediaFilterOptions(rawValue: 1 << 1)
    public static let screenshot = MediaFilterOptions(rawValue: 1 << 2)
    public static let stillImage = MediaFilterOptions(rawValue: 1 << 3)
    
    public static let all: MediaFilterOptions = [.video, .screenshot, .stillImage]
    public static let allPhotos: MediaFilterOptions = [.screenshot, .stillImage]
}

/// Wrapper that pairs media with its metadata for sorted/filtered results
/// Generic over T to support both EncryptedMedia and InteractableMedia<EncryptedMedia>
public struct MediaWithMetadata<T> {
    public let media: T
    public let metadata: EncryptedFileMetadata?
    public let dateTaken: Date?
    public let dateEncrypted: Date?
    public let mediaSubtype: MediaFilterOptions
    
    public init(media: T, metadata: EncryptedFileMetadata?,
                dateTaken: Date?, dateEncrypted: Date?,
                mediaSubtype: MediaFilterOptions) {
        self.media = media
        self.metadata = metadata
        self.dateTaken = dateTaken
        self.dateEncrypted = dateEncrypted
        self.mediaSubtype = mediaSubtype
    }
}

public protocol FileEnumerator {

    func configure(for album: Album, albumManager: AlbumManaging) async
    func enumerateMedia<T: MediaDescribing>() async -> [InteractableMedia<T>]

    /// Enumerates media with sorting and filtering support
    /// - Parameters:
    ///   - sortBy: How to sort results
    ///   - filterBy: Media subtypes to include
    /// - Returns: Array of MediaWithMetadata containing media and extracted metadata
    func enumerateMediaWithMetadata(
        sortBy: MediaSortOption,
        filterBy: MediaFilterOptions
    ) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>]

    /// Returns the total count of stored media across all albums and storage types.
    /// Live Photo components (photo + video) sharing the same ID are counted as a single item.
    func totalStoredMediaCount() async -> Int
}

// NOTE: the empty-returning default impls of `enumerateMediaWithMetadata` and
// `totalStoredMediaCount` were intentionally removed. Silent stubs defeat the
// compiler's conformance enforcement — every backend must implement them.

public protocol FileReader: FileEnumerator {

    func loadMediaPreview<T: MediaDescribing>(for media: InteractableMedia<T>) async throws -> PreviewModel
    func loadMedia<T: MediaDescribing>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia>
    func loadMediaToURLs(
        media: InteractableMedia<EncryptedMedia>,
        progress: @escaping (FileLoadingStatus) -> Void) async throws -> [URL]
    /// Backend-level: resolve the album's leading/cover thumbnail by id.
    /// (The permission-gated variant lives on `FileAccess`, the facade.)
    func loadLeadingThumbnail(coverImageId: String?) async throws -> UIImage?
}

public protocol FileWriter: FileEnumerator {

    @discardableResult func save(media: InteractableMedia<CleartextMedia>, metadata: EncryptedFileMetadata?, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>?
    @discardableResult func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel
    func copy(media: InteractableMedia<EncryptedMedia>) async throws
    func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)?) async throws
    func delete(media: [InteractableMedia<EncryptedMedia>]) async throws
    func deleteAllMedia() async throws
    func setKeyUUIDForExistingFiles() async throws
}

// Real convenience overloads (not silent stubs): default the metadata / progress
// arguments so callers can omit them.
public extension FileWriter {
    func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        return try await save(media: media, metadata: nil, progress: progress)
    }

    func move(media: InteractableMedia<EncryptedMedia>) async throws {
        try await move(media: media, progress: nil)
    }
}

/// The per-album backend contract: everything a disk or cloud backend must do.
/// Composed from the existing `FileReader` / `FileWriter` protocols plus the two
/// genuinely-new backend responsibilities (`reconcile`, `sourceURL`). NOT a
/// parallel stack.
///
/// (The `: Actor` refinement proposed by the migration plan was dropped: several
/// conformers of `FileAccess` — `DemoFileEnumerator` and the test mocks — are
/// plain classes, so constraining the protocol to actors would break them. All
/// real backends are still actors regardless.)
public protocol MediaBackend: FileReader, FileWriter {
    /// Brings the album's media index in sync with its backing store. Disk does a
    /// directory scan (driving `onProgress` as it reads metadata); CloudKit does a
    /// delta sync and ignores `onProgress`. Returns whether the index changed.
    @discardableResult
    func reconcile(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)?
    ) async -> Bool

    /// The on-disk URL where a component's ciphertext lives for this backend —
    /// `id.ext` for disk, the `id#type` blob-cache path for CloudKit. Lets the
    /// facade materialize index entries without type-checking the backend.
    func sourceURL(id: String, type: MediaType) async -> URL

    /// The album's current media index — served warm from an in-memory cache
    /// when possible, otherwise loaded from the backing store (reloading if the
    /// on-disk file is newer than the cache). The backend owns its index: it is
    /// written incrementally on every mutation and rebuilt by `reconcile`, so
    /// this is the single read path the facade's pager draws from. Returns `nil`
    /// when no index has been built yet.
    func mediaIndex() async -> MediaIndex?

    /// A streaming player item for a video the backend can serve incrementally,
    /// or `nil` when the item plays through the ordinary materialize-then-decrypt
    /// path. Only the CloudKit backend answers non-nil today — for a chunked
    /// video whose bytes live as `EncBlobChunk` records.
    func streamingPlayback(for media: InteractableMedia<EncryptedMedia>) async throws -> StreamingPlayback?

    /// Where the item's ciphertext lives, what it costs in each place, and which
    /// container format holds it. Purely observational — no download is triggered
    /// to answer, so a cloud blob that is neither chunked nor cached honestly
    /// reports an unknown format rather than fetching bytes to find out.
    func storageDetails(for media: InteractableMedia<EncryptedMedia>) async -> MediaStorageDetails?

    /// Drops this device's re-downloadable copy of the item, leaving the remote
    /// copy untouched. Throws `FileAccessError.localCopyNotEvictable` on a backend
    /// where the local bytes *are* the only copy — evicting there would be a
    /// silent delete, which is what the separate `delete` path is for.
    func evictLocalCopy(for media: InteractableMedia<EncryptedMedia>) async throws
}

public extension MediaBackend {
    /// Default: nothing streams; every backend but CloudKit materializes.
    func streamingPlayback(for media: InteractableMedia<EncryptedMedia>) async throws -> StreamingPlayback? {
        nil
    }
}

/// The facade contract (what app callers depend on): a full backend PLUS the
/// orchestration-level extras that are not a backend's job.
public protocol FileAccess: MediaBackend {
    init()
    init(for album: Album, albumManager: AlbumManaging) async
    func loadLeadingThumbnail(purchasedPermissions: (any PurchasedPermissionManaging)?) async throws -> UIImage?
    static func deleteThumbnailDirectory() throws
}

extension FileAccess {
    var operationBus: FileOperationBus {
        FileOperationBus.shared
    }
}
