import Foundation
import PhotosUI
import Photos

public enum InteractableMediaType: Hashable {
    case stillPhoto
    case livePhoto
    case video

    public var fileExtension: String {
        switch self {
        case .video:
            return "video"
        case .livePhoto, .stillPhoto:
            return "image"
        }
    }
}

public enum InteractableMediaError: Error {
    case unknownMediaType
    case idMismatch
}

public class InteractableMedia<T: MediaDescribing>: Hashable, Identifiable, Equatable {

    public var mediaType: InteractableMediaType
    public var timestamp: Date? {
        return underlyingMedia.first?.timestamp
    }
    public var id: String


    public init(emptyWithType type: InteractableMediaType, id: String) {
        self.mediaType = type
        self.id = id
        self.underlyingMedia = []
    }
    
    public init(underlyingMedia: [T]) throws {
        let underlyingMediaTypes = Set(underlyingMedia.map { $0.mediaType }.filter({$0 != .unknown && $0 != .preview}))
        guard !underlyingMediaTypes.isEmpty else {
            throw InteractableMediaError.unknownMediaType
        }

        if underlyingMediaTypes.count == 1 {
            switch underlyingMediaTypes.first {
            case .photo:
                mediaType = .stillPhoto
            case .video:
                mediaType = .video
            default:
                throw InteractableMediaError.unknownMediaType
            }
        } else if underlyingMediaTypes.subtracting([.photo, .video]).count == 0 {
            mediaType = .livePhoto
        } else {
            throw InteractableMediaError.unknownMediaType
        }
        let idSet = Set(underlyingMedia.map { $0.id })
        if idSet.count > 1 {
            throw InteractableMediaError.idMismatch
        }
        self.id = idSet.first!
        self.underlyingMedia = underlyingMedia
    }

    public var underlyingMedia: [T]
    public var thumbnailSource: T! {
        switch mediaType {
        case .stillPhoto:
            return underlyingMedia.first
        case .livePhoto:
            return underlyingMedia.filter({$0.mediaType == .photo}).first
        case .video:
            return underlyingMedia.first
        }
    }

    public var imageData: Data? {
        switch mediaType {
        case .stillPhoto, .livePhoto:
            if let cleartext = underlyingMedia.filter({$0.mediaType == .photo}).first as? CleartextMedia,
               case .data(let data) = cleartext.source {
                return data
            }
            return nil
        case .video:
            return nil
        }
    }

    public var photoURL: URL? {
        switch mediaType {
        case .stillPhoto, .livePhoto:
            if let cleartext = underlyingMedia.filter({$0.mediaType == .photo}).first as? CleartextMedia,
               case .url(let url) = cleartext.source {
                return url
            }
            return nil
        case .video:
            return nil
        }
    }

    public var videoURL: URL? {
        switch mediaType {
        case .stillPhoto:
            return nil
        case .livePhoto, .video:
            if let cleartext = underlyingMedia.filter({$0.mediaType == .video}).first as? CleartextMedia,
               case .url(let url) = cleartext.source {
                return url
            }
            return nil
        }
    }

    public var gridID: String {
        "\(mediaType.fileExtension)_\(id)"
    }

    public func appendToUnderlyingMedia(media: T) {
        underlyingMedia.append(media)
        if underlyingMedia.contains(where: {$0.mediaType == .video || $0.mediaType == .video}) {
            mediaType = .livePhoto
        }
    }
}

extension InteractableMedia {
    public static func == (lhs: InteractableMedia<T>, rhs: InteractableMedia<T>) -> Bool {
        return lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension InteractableMedia where T == EncryptedMedia {
    public var needsDownload: Bool {
        return underlyingMedia.first?.needsDownload ?? false
    }
}
