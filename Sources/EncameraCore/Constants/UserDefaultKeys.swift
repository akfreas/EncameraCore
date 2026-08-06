//
//  UserDefaultKeys.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation

public enum UserDefaultKey {
    
    
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
    case credentialConflictResolution
    case biometricsConfirmedOnThisDevice
    /// The one-launch upgrade-seeding window for `biometricsConfirmedOnThisDevice`
    /// has been evaluated, whether or not it seeded. Without this marker the
    /// fresh-device decline is not sticky: the caller records the launch right
    /// after, so the re-derived "has launched before" bit reads true on launch 2
    /// and the seed would adopt another device's synced intent after all.
    case biometricsSeedWindowClosed
    /// Sticky, device-local dismissal of the iCloud Drive -> CloudKit migration
    /// prompt. Someone with a large Drive album may reasonably defer forever, so
    /// once dismissed the prompt never reappears on this device.
    case dismissediCloudDriveMigrationPrompt
    /// How many evicted iCloud Drive files the migration materializes before
    /// uploading them. Tunable rather than a constant because the right value is an
    /// empirical trade-off between free disk on the device and how often the
    /// migration has to stop and wait on downloads — and the only way to find it is
    /// to run real albums on real hardware. `0`/unset means the engine default.
    case iCloudDriveMigrationBatchSize
    /// An "Erase All Data" completed locally but the CloudKit zone deletion failed
    /// (offline / transient error). Written AFTER the defaults wipe so it survives
    /// it; the app retries the cloud wipe on launch until it succeeds.
    case pendingCloudDataWipe
    /// Which typeface `EncameraFont` renders body text in. Debug-only, driven by
    /// the Font Configuration screen behind the `showFontConfig` toggle.
    case fontFamily
    /// Points added to every body-text `EncameraFont` size. Debug-only, same
    /// screen; unset means the shipped default.
    case fontSizeOffset

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
        case .onboardingState,
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
             .completedMigration,
             // Which of two conflicting credential sets this device uses is
             // inherently device-specific — it must never sync.
             .credentialConflictResolution,
             // Biometric consent is per-device: the enrolled face/finger is
             // this device's hardware. The account-wide intent lives in the
             // always-synced AuthenticationConfiguration; this flag is the
             // confirmation that the user opted in ON THIS DEVICE.
             .biometricsConfirmedOnThisDevice,
             // The seed window is per-install by definition: it exists to stop
             // one device's intent from leaking onto another.
             .biometricsSeedWindowClosed,
             // Deferring the migration prompt is a per-device decision: another
             // device may not even have the legacy albums, and syncing the
             // dismissal would silently suppress the prompt where it still applies.
             .dismissediCloudDriveMigrationPrompt,
             // A debug tunable measured against one device's free space and network;
             // syncing it would push one phone's experiment onto every other.
             .iCloudDriveMigrationBatchSize,
             .pendingCloudDataWipe,
             // A typography experiment run against one device's screen. Syncing
             // it would push one phone's experiment onto every other.
             .fontFamily,
             .fontSizeOffset:
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
