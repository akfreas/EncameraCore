//
//  AppConstants.swift
//  encamera
//
//  Created by Alexander Freas on 11.11.21.
//

import Foundation

public enum AppConstants {
    
    public static var authenticationTimeout: RunLoop.SchedulerTimeType.Stride = 20
    public static var deeplinkSchema = "encamera"
    public static var thumbnailWidth: CGFloat = 100
    public static var blockingBlurRadius: CGFloat = 20.0
    public static var defaultCornerRadius: CGFloat = 10.0
    public static var numberOfPhotosBeforeInitialTutorial: Double = 1
    public static let maxPhotoCountBeforePurchase: Double = 10
    public static let defaultAlbumName: String = L10n.defaultAlbumName
    public static let defaultKeyName: String = "encamera_default_key"
    public static let reviewRequestThreshold = 3
    public static let requestForTweetFrequency = 3
    public static let lowOpacity = 0.4
    public static let previewDirectory = "preview_thumbnails"
    public static let appStoreURL = "https://apps.apple.com/us/app/encamera-encrypted-photo-vault/id1639202616"
    public static let pinCodeLength = 4
    public static let lockoutTime: TimeInterval = 300
    public static let maxCharacterAlbumName = 20
    public static let widgetVimeoLink = URL(string: "https://vimeo.com/896507875")!
    public static var isInPromoMode: Bool {
        let currentDate = Date()
        let promoEndDateComponents = DateComponents(year: 2024, month: 11, day: 3)
        let calendar = Calendar.current
        if let promoEndDate = calendar.date(from: promoEndDateComponents) {
            return currentDate <= promoEndDate
        }
        return false
    }
}
