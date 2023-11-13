//
//  ImageKeyDirectoryStorage.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

public protocol DataStorageSetting {
    func storageModelFor(album: Album?) -> DataStorageModel?
    func setStorageTypeFor(album: Album, directoryModelType: StorageType)
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
        static func directoryTypeKeyFor(album: Album) -> String {
            return "encamera.keydirectory.\(album.name)"
        }
    }
    
    public init() {}
    
    public func storageModelFor(album: Album?) -> DataStorageModel? {

        guard let album else {
            return nil
        }
        guard let directoryModelString = UserDefaultUtils.value(forKey: .directoryTypeKeyFor(album: album)) as? String,
              let type = StorageType(rawValue: directoryModelString) else {
            let model = determineStorageModelFor(album: album) ?? LocalStorageModel(album: album)
            setStorageTypeFor(album: album, directoryModelType: model.storageType)
            return model
        }
        
        let model = type.modelForType.init(album: album)

        return model
    }
    
    public func determineStorageModelFor(album: Album) -> DataStorageModel? {

        let local = LocalStorageModel(album: album)
        if FileManager.default.fileExists(atPath: local.baseURL.path) {
            return local
        }
        
        guard case .available = isStorageTypeAvailable(type: .icloud) else {
            return local
        }
        
        let remote = iCloudStorageModel(album: album)
        _ = remote.baseURL.startAccessingSecurityScopedResource()
        defer {
            remote.baseURL.stopAccessingSecurityScopedResource()
        }
        if FileManager.default.fileExists(atPath: remote.baseURL.path) {
            return remote
        }
        return nil
    }
    
    public func setStorageTypeFor(album: Album, directoryModelType: StorageType) {
        UserDefaultUtils.set(directoryModelType.rawValue, forKey: .directoryTypeKeyFor(album: album))
    }
}
