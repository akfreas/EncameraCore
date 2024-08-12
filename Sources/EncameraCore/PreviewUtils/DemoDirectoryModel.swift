import Foundation
public class DemoDirectoryModel: DataStorageModel {
    public static var rootURL: URL = URL(fileURLWithPath: "")


    public var storageType: StorageType = .local

    public var album: Album = Album(name: "Test", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey())

    public var baseURL: URL

    public var thumbnailDirectory: URL

    public required init(album: Album) {
        self.baseURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).appendingPathComponent("base")
        self.thumbnailDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                      isDirectory: true).appendingPathComponent("thumbs")
    }

    public convenience init() {
        self.init(album: Album(name: "", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey()))
    }


    func deleteAllFiles() throws {
       try  [baseURL, thumbnailDirectory].forEach { url in
            guard let enumerator = FileManager.default.enumerator(atPath: url.path) else {
                return
            }
            try enumerator.compactMap { item in
                guard let itemUrl = item as? URL else {
                    return nil
                }
                return itemUrl
            }
            .forEach { (file: URL) in
                try FileManager.default.removeItem(at: file)
                debugPrint("Deleted file at \(file)")
            }
        }
    }

}
