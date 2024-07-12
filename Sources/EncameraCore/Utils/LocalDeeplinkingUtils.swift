//
//  LocalDeeplinkingUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation
import UIKit

public class LocalDeeplinkingUtils {
    
    public static func openInFiles<T: MediaDescribing>(media: T)  {
        guard case .url(let url) = media.source,
            let url = url.driveDeeplink() else {
            debugPrint("Could not create deeplink")
            return
        }
        
        UIApplication.shared.open(url)
    }
    
    public static func openAlbumContentsInFiles(albumManager: AlbumManaging, album: Album) {

        let model = albumManager.storageModel(for: album)
        guard let url = model?.baseURL.driveDeeplink() else {
            debugPrint("Could not create deeplink")
            return
        }
        
        UIApplication.shared.open(url)
    }
    
    public static func deeplinkFor(key: PrivateKey) -> URL? {
        
        return URLType.key(key: key).url
    }
}

private extension URL {
    
    func driveDeeplink() -> URL? {
        return URL(string: absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://"))
    }
}
