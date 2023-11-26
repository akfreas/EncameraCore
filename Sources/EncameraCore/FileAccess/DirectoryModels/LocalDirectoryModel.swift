//
//  LocalDirectoryModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

struct LocalStorageModel: DataStorageModel {
    static var rootURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]

        return documentsDirectory
    }

    
    var storageType: StorageType {
        .local
    }
    
    var baseURL: URL {
        let filesDirectory = Self.rootURL.appendingPathComponent(album.name)
        return filesDirectory
    }
    
    var album: Album
}
