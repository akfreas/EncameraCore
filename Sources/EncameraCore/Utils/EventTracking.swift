//
//  EventTracking.swift
//  Encamera
//
//  Created by Alexander Freas on 02.12.23.
//

import Foundation
import PiwikPROSDK

@MainActor
public class EventTracking {
    public let piwikTracker: PiwikTracker = PiwikTracker.sharedInstance(siteID: "5ed9378f-f689-439c-ba90-694075efc81a", baseURL: URL(string: "https://encamera.piwik.pro/piwik.php")!)!
    public static let shared = EventTracking()

    private init() {
        // set device locale as custom dimension
        piwikTracker.setCustomDimension(identifier: 1, value: Locale.current.identifier)
        piwikTracker.isAnonymizationEnabled = false
    }

    private static func track(category: String, action: String, name: String? = nil, value: Float? = nil) {
#if DEBUG
        debugPrint("[Tracking] Category: \(category), action: \(action), name: \(name ?? "none"), value: \(value ?? 0)")
#else
        if FeatureToggle.isEnabled(feature: .stopTracking) {
            return
        }
        Self.shared.piwikTracker.sendEvent(category: category, action: action, name: name, value: value as NSNumber?, path: nil)
#endif
    }

    public static func setSubscriptionDimensions(productID: String?) {
        #if DEBUG
        return
        #else
        if let productID {
            Self.shared.piwikTracker.setCustomDimension(identifier: 2, value: productID)
        }
        #endif
    }

    public static func trackAppLaunched() {
        track(category: "app", action: "launched")
    }

    public static func trackOpenedCameraFromWidget() {
        track(category: "app", action: "opened_camera_from_widget")
    }

    public static func trackOpenedCameraFromBottomBar() {
        track(category: "camera", action: "opened", name: "bottom_bar")
    }

    public static func trackOpenedCameraFromAlbumEmptyState() {
        track(category: "camera", action: "opened", name: "album_empty_state")
    }

    public static func trackCameraButtonPressed() {
        track(category: "camera", action: "button_pressed")
    }

    public static func livePhotoModeSet(to: Bool) {
        track(category: "camera", action: "live_photo_toggled", name: to ? "true" : "false")
    }

    public static func trackMediaTaken(type: CameraMode, isLivePhotoEnabled: Bool? = nil, videoDuration: Double? = nil) {
        var title = type.title
        if isLivePhotoEnabled != nil {
            title = isLivePhotoEnabled! ? "live_photo" : "photo"
        }
        if let videoDuration {
            track(category: "camera", action: "media_captured", name: title, value: Float(videoDuration))
        } else {
            track(category: "camera", action: "media_captured", name: title)
        }
    }

    public static func trackCameraClosed() {
        track(category: "camera", action: "closed")
    }

    public static func trackAlbumOpened() {
        track(category: "album", action: "opened")
    }

    public static func trackAlbumSelectedFromTopBar() {
        track(category: "album", action: "selected", name: "top_bar")
    }

    public static func trackMediaImportOpened() {
        track(category: "media", action: "import_opened")
    }

    public static func trackMediaImported(count: Int) {
        track(category: "media", action: "media_imported", value: Float(count))
    }

    public static func trackMediaDeleted(count: Int) {
        track(category: "media", action: "media_deleted", value: Float(count))
    }

    public static func trackFilesImported(count: Int) {
        track(category: "media", action: "file_imported", value: Float(count))
    }

    public static func trackImageViewed() {
        track(category: "media", action: "viewed", name: "image")
    }

    public static func trackLivePhotoViewed() {
        track(category: "media", action: "viewed", name: "live_photo")
    }

    public static func trackMovieViewed() {
        track(category: "media", action: "viewed", name: "movie")
    }

    public static func trackMediaShared(count: Int) {
        track(category: "media", action: "shared", value: Float(count))
    }

    public static func trackOnboardingViewReached(view: OnboardingFlowScreen, new: Bool = false) {
        track(category: "\(new ? "new_": "")onboarding", action: "view_reached", name: view.rawValue)
    }

    public static func trackOnboardingFinished(new: Bool = false) {
        track(category: "\(new ? "new_" : "")onboarding", action: "finished")
    }

    public static func trackPhotoLimitReachedScreenUpgradeTapped(from screen: String) {
        track(category: "photo_limit_reached", action: "upgrade_tapped", name: screen)
    }

    public static func trackPhotoLimitReachedScreenDismissed(from screen: String) {
        track(category: "photo_limit_reached", action: "dismissed", name: screen)
    }

    public static func trackConfirmStorageTypeSelected(type: StorageType) {
        track(category: "storage_type", action: "selected", name: type.rawValue)
    }

    public static func trackShowPurchaseScreen(from screen: String) {
        track(category: "purchase", action: "show", name: screen)
    }

    public static func trackPurchaseCompleted(from screen: String, currency: String, amount: Decimal, product: String) {
        track(category: "purchase_completed", action: product.lowercased(), name: screen)
    }

    public static func trackPurchaseScreenDismissed(from screen: String) {
        track(category: "purchase", action: "dismissed", name: screen)
    }

    public static func trackPurchaseIncomplete(from screen: String, product: String) {
        track(category: "purchase_incomplete", action: product.lowercased(), name: screen)
    }

    public static func trackPurchaseCancelled(from screen: String, product: String) {
        track(category: "purchase_cancelled", action: product.lowercased(), name: screen)
    }

    public static func trackPurcasePending(from screen: String, product: String) {
        track(category: "purchase_pending", action: product.lowercased(), name: screen)
    }

    public static func trackBiometricsEnabled() {
        track(category: "biometrics", action: "enabled", name: "settings")
    }

    public static func trackBiometricsDisabled() {
        track(category: "biometrics", action: "disabled", name: "settings")
    }

    public static func trackOnboardingBiometricsEnabled(newOnboarding: Bool = false) {
        track(category: "biometrics", action: "enabled", name: "\(newOnboarding ? "new_" : "")onboarding")
    }

    public static func trackOnboardingBiometricsSkipped() {
        track(category: "biometrics", action: "skipped", name: "onboarding")
    }

    public static func trackCameraPermissionsDenied() {
        track(category: "permissions", action: "permissions_denied", name: "camera")
    }

    public static func trackCameraPermissionsGranted() {
        track(category: "permissions", action: "permissions_granted", name: "camera")
    }

    public static func trackMicrophonePermissionsDenied() {
        track(category: "permissions", action: "permissions_denied", name: "microphone")
    }

    public static func trackMicrophonePermissionsGranted() {
        track(category: "permissions", action: "permissions_granted", name: "microphone")
    }

    public static func trackCameraPermissionsTapped() {
        track(category: "permissions", action: "permissions_tapped", name: "camera")
    }

    public static func trackMicrophonePermissionsTapped() {
        track(category: "permissions", action: "permissions_tapped", name: "microphone")
    }

    public static func trackNotificationPermissionsDenied() {
        track(category: "permissions", action: "permissions_denied", name: "notifications")
    }

    public static func trackNotificationPermissionsGranted() {
        track(category: "permissions", action: "permissions_granted", name: "notifications")
    }

    public static func trackNotificationOpened(name: String) {
        track(category: "notification", action: "opened", name: name)
    }

    public static func trackAlbumCreated() {
        track(category: "album", action: "created")
    }

    public static func trackAlbumCoverRemoved() {
        track(category: "album", action: "cover_removed")
    }

    public static func trackAlbumCoverReset() {
        track(category: "album", action: "cover_reset")
    }

    public static func trackAlbumCoverSet() {
        track(category: "album", action: "cover_set")
    }

    public static func trackAppOpened() {
        track(category: "app", action: "opened")
    }

    public static func trackCreateAlbumButtonPressed() {
        track(category: "album", action: "create_button_pressed")
    }

    public static func trackNotificationBellPressed() {
        track(category: "notification", action: "bell_pressed")
    }

    public static func trackSettingsTelegramPressed() {
        track(category: "settings", action: "telegram_pressed")
    }

    public static func trackSettingsContactPressed() {
        track(category: "settings", action: "contact_pressed")
    }

    public static func trackSettingsLeaveReviewPressed() {
        track(category: "settings", action: "leave_review_pressed")
    }

    public static func trackNotificationSwipedViewed(title: String) {
        track(category: "notification_banner", action: "viewed", name: title)
    }

    public static func trackNotificationButtonTapped(url: URL) {
        track(category: "notification_banner", action: "button_tapped", name: url.absoluteString)
    }

    public static func trackKeyPhraseBackupCopied() {
        track(category: "key_phrase", action: "phrase_copied")
    }

    public static func trackKeyPhraseBackupImported() {
        track(category: "key_phrase", action: "phrase_imported")
    }

    public static func trackKeyPhraseBackupScreenOpened() {
        track(category: "key_phrase", action: "backup_screen_opened")
    }

    public static func trackImportKeyPhraseScreenOpened() {
        track(category: "key_phrase", action: "import_screen_opened")
    }

    public static func trackKeyMigrationPrepared() {
        track(category: "key_migration", action: "prepared")
    }

    public static func trackKeyMigrationCompleted() {
        track(category: "key_migration", action: "completed")
    }

    public static func trackKeyMigrationFailedWithError() {
        track(category: "key_migration", action: "failed")
    }

    public static func trackPhotoLibraryPermissionsGranted() {
        track(category: "permissions", action: "permissions_granted", name: "photo_library")
    }

    public static func trackPhotoLibraryPermissionsDenied() {
        track(category: "permissions", action: "permissions_denied", name: "photo_library")
    }

    public static func trackPhotoLibraryPermissionsLimited() {
        track(category: "permissions", action: "permissions_limited", name: "photo_library")
    }

    public static func trackNotificationPromptShown() {
        track(category: "notification_prompt", action: "shown")
    }
    public static func trackNotificationPromptDismissed() {
        track(category: "notification_prompt", action: "dismissed")
    }

    public static func trackNotificationPromptAccepted() {
        track(category: "notification_prompt", action: "accepted")
    }

    public static func trackReviewAlertNoPressed() {
        track(category: "review_alert", action: "no_pressed")
    }

    public static func trackReviewAlertYesPressed() {
        track(category: "review_alert", action: "yes_pressed")
    }

    public static func trackReviewAlertAskLaterPressed() {
        track(category: "review_alert", action: "ask_later_pressed")
    }

    public static func trackAuthenticationMethodChanged(to type: String) {
        track(category: "authentication", action: "method_changed", name: type)
    }

    public static func trackAuthenticationMethodCleared() {
        track(category: "authentication", action: "method_cleared")
    }
}
