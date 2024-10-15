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
    case directoryTypeKeyFor(album: Album)
    case savedSettings
    case capturedPhotos
    case featureToggle(feature: Feature)
    case viewGalleryCount
    case reviewRequestedMetric
    case lastVersionReviewRequested
    case hasOpenedAlbum
    case keyTutorialClosed
    case currentAlbumID
    case showCurrentAlbumOnLaunch
    case usesPinPassword
    case lockoutEnd
    case launchCountKey
    case lastVersionKey
    case photoAddedCount
    case videoAddedCount
    case widgetOpenCount
    case notificationScheduledCount(identifier: NotificationIdentifier)
    case livePhotosActivated
    case defaultStorageLocation
    case showPushNotificationPrompt


    var rawValue: String {
        switch self {
        case .directoryTypeKeyFor(let album):
            return "\(UserDefaultKey.directoryPrefix)\(album.name)"
        case .featureToggle(feature: let feature):
            return "featureToggle_\(feature)"
        case .notificationScheduledCount(identifier: let identifier):
            return "notificationScheduledCount_\(identifier)"
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
