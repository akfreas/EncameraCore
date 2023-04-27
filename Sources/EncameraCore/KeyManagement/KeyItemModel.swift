//
//  KeyItemModel.swift
//  Encamera
//
//  Created by Alexander Freas on 28.11.22.
//

import Foundation
struct KeyItemModel: Identifiable {
    let key: PrivateKey
    let imageCount: Int
    var id: String {
        key.name
    }
}
