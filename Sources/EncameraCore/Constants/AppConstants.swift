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
    public static var thumbnailWidth: CGFloat = 70
    public static var blockingBlurRadius: CGFloat = 10.0
    public static var defaultCornerRadius: CGFloat = 10.0
    public static var numberOfPhotosBeforeInitialTutorial: Double = 1
    public static let maxPhotoCountBeforePurchase: Double = 5
    public static let defaultAlbumName: String = L10n.defaultAlbumName
    public static let numberOfGalleryViewsBeforePromptingForReview = 5
    public static let requestForTweetFrequency = 3
}
