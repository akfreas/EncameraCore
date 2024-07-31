import Foundation
import UIKit

public class DemoFileEnumerator: FileAccess {
    public var directoryModel: DataStorageModel? = DemoDirectoryModel()

    private var mediaList: [InteractableMedia<EncryptedMedia>] = []

    public static var shared = DemoFileEnumerator()

    public required init() {
        Task {
            mediaList = await enumerateMedia()
        }
    }

    public required init(for album: Album, albumManager: AlbumManaging) async {
        mediaList = await enumerateMedia()
    }

    public func configure(for album: Album, albumManager: AlbumManaging) async {
        // Implementation here
    }

    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        // Implementation here
    }

    public func move(media: InteractableMedia<EncryptedMedia>) async throws {
        // Implementation here
    }

    @discardableResult
    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        return PreviewModel(thumbnailMedia: CleartextMedia(source: .data(Data()), mediaType: .preview, id: "sdf"))
    }

    public func deleteMediaForKey() async throws {
        // Implementation here
    }

    public func deleteAllMedia() async throws {
        // Implementation here
    }

    public static func deleteThumbnailDirectory() throws {
        // Implementation here
    }

    public func loadMedia<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T : MediaDescribing {
        return try! InteractableMedia(underlyingMedia: [CleartextMedia(source: .url(URL(fileURLWithPath: "")))])
    }

    public func loadMediaInMemory(media: InteractableMedia<EncryptedMedia>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> {
        let cleartextMedia = CleartextMedia(source: Data())
        return try InteractableMedia(underlyingMedia: [cleartextMedia])
    }

    public func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        let encryptedMedia = EncryptedMedia(source: URL(fileURLWithPath: ""), mediaType: .photo, id: "1234")
        return try InteractableMedia(underlyingMedia: [encryptedMedia])
    }

    public func loadMediaPreview<T: MediaDescribing>(for media: InteractableMedia<T>) async throws -> PreviewModel {
        guard let source = media.photoURL,
              let data = try? Data(contentsOf: source) else {
            return try PreviewModel(source: CleartextMedia(source: Data()))
        }
        let cleartext = CleartextMedia(source: data)
        let preview = PreviewModel(thumbnailMedia: cleartext)
        return preview
    }

    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T : MediaDescribing {
        let retVal: [InteractableMedia<T>] = (7...11).compactMap { val in
            guard let url = Bundle(for: type(of: self)).url(forResource: "\(val)", withExtension: "jpg") else { return nil }
            return try? InteractableMedia(underlyingMedia: [T(source: .url(url), mediaType: .photo, id: "\(val)")])
        }.shuffled()
        return retVal
    }

    public func delete(media: InteractableMedia<EncryptedMedia>) async throws {
        // Implementation here
    }

    public func loadLeadingThumbnail() async throws -> UIImage? {
        guard let last = mediaList.popLast(), case .url(let source) = last.thumbnailSource.source else {
            return nil
        }
        return UIImage(data: try Data(contentsOf: source))
    }
}
