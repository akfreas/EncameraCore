//
//  UserDefaultKeys.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation

public enum UserDefaultKey {
    
    
    case authenticationPolicy
    case currentKey
    case onboardingState
    case directoryTypeKeyFor(keyName: KeyName)
    case savedSettings
    case capturedPhotos
    case featureToggle(feature: Feature)
    case viewGalleryCount
    case lastVersionReviewRequested
    
    var rawValue: String {
        switch self {
        case .directoryTypeKeyFor(let keyName):
            return "\(UserDefaultKey.directoryPrefix)\(keyName)"
        case .featureToggle(feature: let feature):
            return "featureToggle_\(feature)"
        default:
            return String(describing: self)
        
        }
    }
    
    private static var directoryPrefix: String {
        "encamera.keydirectory."
    }
}

extension UserDefaultKey: Equatable {
    public static func ==(lhs: UserDefaultKey, rhs: UserDefaultKey) -> Bool {
        return lhs.rawValue == rhs.rawValue
    }
}
