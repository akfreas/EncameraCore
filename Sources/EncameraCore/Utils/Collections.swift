//
//  Collections.swift
//  Encamera
//
//  Created by Alexander Freas on 20.01.23.
//

import Foundation
extension Collection where Indices.Iterator.Element == Index {
    subscript (safe index: Index) -> Iterator.Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
