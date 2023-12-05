//
//  Album.swift
//
//
//  Created by Alexander Freas on 26.10.23.
//

import Foundation
import Combine

public struct Album: Codable, Identifiable, Hashable {

    public init(name: String, storageOption: StorageType, creationDate: Date, key: PrivateKey) {
        self.name = name
        self.storageOption = storageOption
        self.creationDate = creationDate
        self.key = key
    }
    public var key: PrivateKey
    public var name: String
    public var storageOption: StorageType
    public var creationDate: Date
    public var id: String {
        return name
    }
    public var storageURL: URL {
        storageOption.modelForType.init(album: self).baseURL
    }
}
