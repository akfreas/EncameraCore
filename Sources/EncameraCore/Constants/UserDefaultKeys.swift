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
    case lockoutEnd
    case launchCountKey
    case lastVersionKey
    case photoAddedCount
    case videoAddedCount
    case widgetOpenCount
    case livePhotosActivated
    case defaultStorageLocation
    case showPushNotificationPrompt
    case isAlbumHidden(name: String)
    case albumCoverImage(albumName: String)
    case passcodeType
    case gridZoomLevel
    case gridSortOption
    case showHiddenAlbumsInCameraPicker
    case loopVideos
    case hasCompletedFirstLockout
    case hasBeenShownHideAlbumTutorial
    case keyBackupPromptLastShown
    case promotionalBannerInteractions
    case dismissedBanners
    case showPaywallOnAppear
    case selectedPhotoResolution
    case selectedVideoQuality
    case keyMigration
    case passphraseMigration
    case passwordHashMigration
    case completedMigration

    var rawValue: String {
        switch self {
        case .directoryTypeKeyFor(let album):
            return "\(UserDefaultKey.directoryPrefix)\(album.name)"
        case .featureToggle(feature: let feature):
            return "featureToggle_\(feature)"
        case .dismissedBanners:
            return "com.encamera.dismissedBanners"
        case .keyMigration:
            return "keyMigration"
        case .passphraseMigration:
            return "passphraseMigration"
        case .passwordHashMigration:
            return "passwordHashMigration"
        case .completedMigration:
            return "completedMigration"
        default:
            return String(describing: self)
        
        }
    }
    
    /// Determines whether this key should sync to iCloud via NSUbiquitousKeyValueStore
    /// Critical authentication and settings keys sync, while device-specific metrics stay local
    var shouldSyncToiCloud: Bool {
        switch self {
        // MUST SYNC: Critical authentication and onboarding state
        case .authenticationPolicy,
             .onboardingState,
             .savedSettings,
             .currentAlbumID,
             .showCurrentAlbumOnLaunch,
             .keyTutorialClosed,
             .hasOpenedAlbum,
             .defaultStorageLocation,
             .livePhotosActivated,
             .gridZoomLevel,
             .gridSortOption,
             .currentKey,
             .hasCompletedFirstLockout,
             .hasBeenShownHideAlbumTutorial:
            return true
            
        // ALBUM-SPECIFIC: Sync album settings
        case .directoryTypeKeyFor,
             .isAlbumHidden,
             .albumCoverImage:
            return true
            
        // LOCAL ONLY: Device-specific metrics, counts, and temporary state
        case .capturedPhotos,
             .featureToggle,
             .viewGalleryCount,
             .reviewRequestedMetric,
             .lastVersionReviewRequested,
             .lockoutEnd,
             .launchCountKey,
             .lastVersionKey,
             .photoAddedCount,
             .videoAddedCount,
             .widgetOpenCount,
             .showPushNotificationPrompt,
             .passcodeType, // Passcode type is now managed via keychain
             .keyBackupPromptLastShown,
             .promotionalBannerInteractions,
             .dismissedBanners,
             .showPaywallOnAppear,
             .selectedPhotoResolution,
             .selectedVideoQuality,
             .showHiddenAlbumsInCameraPicker,
             .loopVideos,
             .keyMigration,
             .passphraseMigration,
             .passwordHashMigration,
             .completedMigration:
            return false
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
