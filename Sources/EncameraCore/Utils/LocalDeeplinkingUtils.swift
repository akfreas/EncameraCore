//
//  LocalDeeplinkingUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation
import UIKit

public class LocalDeeplinkingUtils {
    
    public static func openInFiles<T: MediaDescribing>(media: T) where T.MediaSource == URL {
        guard let url = media.source.driveDeeplink() else {
            debugPrint("Could not create deeplink")
            return
        }
        
        UIApplication.shared.open(url)
    }
    
    public static func openAlbumContentsInFiles(album: Album) {

        let storageSetting = DataStorageUserDefaultsSetting()
        let model = storageSetting.storageModelFor(album: album)
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
