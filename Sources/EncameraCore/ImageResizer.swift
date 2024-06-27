import Foundation
import UIKit

enum ImageResizingError: Error {
    case cannotRetrieveFromURL
    case cannotRetrieveFromData
}

public struct ImageResizer {
    var targetWidth: CGFloat

    public func resize(at url: URL, quality: CGFloat) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }

        return self.resize(image: image, quality: quality)
    }

    public func resize(image: UIImage, quality: CGFloat) -> UIImage? {
        let originalSize = image.size
        let targetSize = CGSize(width: targetWidth, height: targetWidth * originalSize.height / originalSize.width)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { (context) in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpegData = resizedImage.jpegData(compressionQuality: quality) else {
            return nil
        }
        return UIImage(data: jpegData)
    }

    public func resize(data: Data, quality: CGFloat) -> UIImage? {
        guard let image = UIImage(data: data) else {
            return nil
        }
        return resize(image: image, quality: quality)
    }
}

struct MemorySizer {
    static func size(of data: Data) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB] // optional: restricts the units to MB only
        bcf.countStyle = .file
        let string = bcf.string(fromByteCount: Int64(data.count))
        return string
    }
}
