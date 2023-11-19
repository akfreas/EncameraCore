//
//  Album.swift
//
//
//  Created by Alexander Freas on 26.10.23.
//

import Foundation

public struct Album: Codable {

    init(name: String, storageOption: StorageType, creationDate: Date) {
        self.name = name
        self.storageOption = storageOption
        self.creationDate = creationDate
    }

    public var name: String
    public var storageOption: StorageType
    public var creationDate: Date
}
