//
//  DebugPrintable.swift
//
//
//  Created by Alexander Freas on 21.12.23.
//

import Foundation
public protocol DebugPrintable {

}

extension DebugPrintable {
    public static func printDebug(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let className = String(describing: type(of: self))
        let message = items.map { "\($0)" }.joined(separator: separator)
        print("\(className): \(message)", terminator: terminator)
    }

    public func printDebug(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        Self.printDebug(items, separator: separator, terminator: terminator)
    }
}

