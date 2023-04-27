//
//  ImageKeyDirectoryStorage.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

public protocol DataStorageSetting {
    func storageModelFor(keyName: KeyName?) -> DataStorageModel?
    func setStorageTypeFor(keyName: KeyName, directoryModelType: StorageType)
}

public extension DataStorageSetting {
    
    var preselectedStorageSetting: StorageAvailabilityModel? {
        storageAvailabilities().filter({$0.availability == .available}).first
    }
    
    func isStorageTypeAvailable(type: StorageType) -> StorageType.Availability {
        switch type {
        case .icloud:
            if FileManager.default.ubiquityIdentityToken == nil {
                return .unavailable(reason: L10n.noICloudAccountFoundOnThisDevice)
            } else {
                return .available
            }
        case .local:
            return .available
        }
    }
    
    func storageAvailabilities() -> [StorageAvailabilityModel] {
        var availabilites = [StorageAvailabilityModel]()
        for type in StorageType.allCases {
            let result = isStorageTypeAvailable(type: type)
            availabilites += [StorageAvailabilityModel(storageType: type, availability: result)]
        }
        return availabilites
    }
}

public struct DataStorageUserDefaultsSetting: DataStorageSetting {
    
    private enum Constants {
        static func directoryTypeKeyFor(keyName: KeyName) -> String {
            return "encamera.keydirectory.\(keyName)"
        }
    }
    
    public init() {}
    
    public func storageModelFor(keyName: KeyName?) -> DataStorageModel? {
        
        guard let keyName = keyName else {
            return nil
        }
        guard let directoryModelString = UserDefaultUtils.value(forKey: .directoryTypeKeyFor(keyName: keyName)) as? String,
              let type = StorageType(rawValue: directoryModelString) else {
            let model = determineStorageModelFor(keyName: keyName) ?? LocalStorageModel(keyName: keyName)
            setStorageTypeFor(keyName: keyName, directoryModelType: model.storageType)
            return model
        }
        
        let model = type.modelForType.init(keyName: keyName)
        
        return model
    }
    
    public func determineStorageModelFor(keyName: KeyName) -> DataStorageModel? {
        
        let local = LocalStorageModel(keyName: keyName)
        if FileManager.default.fileExists(atPath: local.baseURL.path) {
            return local
        }
        
        guard case .available = isStorageTypeAvailable(type: .icloud) else {
            return local
        }
        
        let remote = iCloudStorageModel(keyName: keyName)
        _ = remote.baseURL.startAccessingSecurityScopedResource()
        defer {
            remote.baseURL.stopAccessingSecurityScopedResource()
        }
        if FileManager.default.fileExists(atPath: remote.baseURL.path) {
            return remote
        }
        return nil
    }
    
    public func setStorageTypeFor(keyName: KeyName, directoryModelType: StorageType) {
        UserDefaultUtils.set(directoryModelType.rawValue, forKey: .directoryTypeKeyFor(keyName: keyName))
        
    }
}
