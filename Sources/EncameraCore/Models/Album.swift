//
//  Album.swift
//
//
//  Created by Alexander Freas on 26.10.23.
//

import Foundation

public struct Album: Codable {

    public var name: String
    public var storageOption: StorageType
    public var creationDate: Date
}
