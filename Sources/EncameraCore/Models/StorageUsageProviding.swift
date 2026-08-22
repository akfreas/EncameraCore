//
//  StorageUsageProviding.swift
//  EncameraCore
//
//  The seam the storage screen's view model depends on, so it can be tested
//  without a disk to walk.
//

import Foundation

public protocol StorageUsageProviding: Sendable {
    func breakdown() async throws -> StorageUsageBreakdown
}

extension StorageUsageCalculator: StorageUsageProviding {}
