import Foundation
import AVFoundation
import UIKit

public struct MovieUtils {
    public static func generateThumbnailFromVideo(at path: URL) -> UIImage? {
        do {
            let asset = AVURLAsset(url: path, options: nil)
            let imgGenerator = AVAssetImageGenerator(asset: asset)
            imgGenerator.appliesPreferredTrackTransform = true
            let cgImage = try imgGenerator.copyCGImage(at: CMTimeMake(value: 0, timescale: 1), actualTime: nil)
            
            let thumbnail = UIImage(cgImage: cgImage)
            return thumbnail
        } catch let error {
            debugPrint("Error generating thumbnail at path \(path): \(error.localizedDescription)")
            return nil
        }
    }
    
}
