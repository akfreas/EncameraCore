//
//  StorageType.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation

public struct StorageAvailabilityModel: Identifiable, Equatable {
    public let storageType: StorageType
    public let availability: StorageType.Availability
    public var id: StorageType {
        storageType
    }
}

public enum StorageType: String {
    case icloud
    case local
    
    public enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }
    
    public var modelForType: DataStorageModel.Type {
        switch self {
        case .icloud:
            return iCloudStorageModel.self
        case .local:
            return LocalStorageModel.self
        }
    }

    
}

extension StorageType: Identifiable, CaseIterable {
    public var id: Self { self }
    public var title: String {
        switch self {
        case .icloud:
            return "iCloud"
        case .local:
            return L10n.local
        }
    }
    
    public var iconName: String {
        switch self {
        case .icloud:
            return "lock.icloud"
        case .local:
            return "lock.iphone"
        }
    }
    
    public var description: String {
        switch self {
        case .icloud:
            return L10n.savesEncryptedFilesToICloudDrive
        case .local:
            return L10n.savesEncryptedFilesToThisDevice
        }
    }
    
}
