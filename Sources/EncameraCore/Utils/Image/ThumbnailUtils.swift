//  Created by Alexander Freas on 11.05.23.
//

import Foundation
import AVFoundation
import UIKit

public struct ThumbnailUtils {
    
    static func createThumbnailMediaFrom(cleartext media: CleartextMedia) async throws -> CleartextMedia {
        let thumbnailData = try await createThumbnailDataFrom(cleartext: media)
        let cleartextThumb = CleartextMedia(source: thumbnailData, mediaType: .photo, id: media.id)
        return cleartextThumb
    }
    
    public static func createThumbnailImageFrom(cleartext media: CleartextMedia) async throws -> UIImage? {
        let thumbnailData = try await createThumbnailDataFrom(cleartext: media)
        return UIImage(data: thumbnailData)
    }

    public static func createThumbnailDataFrom(cleartext media: CleartextMedia) async throws -> Data {
        
        var thumbnailSourceData: Data
        if let url = media.url {
            switch media.mediaType {
            case .photo:
                thumbnailSourceData = try Data(contentsOf: url)
            case .video:
                guard let thumb = generateThumbnailFromVideo(at: url),
                      let data = thumb.pngData() else {
                    throw SecretFilesError.createVideoThumbnailError
                }
                thumbnailSourceData = data
            default:
                throw SecretFilesError.fileTypeError
            }
        } else if let data = media.data {
            switch media.mediaType {
            case .photo:
                thumbnailSourceData = data
            default:
                throw SecretFilesError.fileTypeError
            }
        } else {
            fatalError()
        }
        let resizer = ImageResizer(targetWidth: AppConstants.thumbnailWidth)
        guard let thumbnailData = resizer.resize(data: thumbnailSourceData, quality: 1.0)?.pngData() else {
            fatalError()
        }

        debugPrint("Thumbnail size: \(MemorySizer.size(of: thumbnailData)) original size: \(MemorySizer.size(of: thumbnailSourceData))")

        return thumbnailData
    }
    
    public static func generateThumbnailFromVideo(at url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        var time = asset.duration
        time.value = min(time.value, 2)

        do {
            let imageRef = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: imageRef)
        } catch {
            print("Error generating thumbnail: \(error)")
            return nil
        }
    }

}

