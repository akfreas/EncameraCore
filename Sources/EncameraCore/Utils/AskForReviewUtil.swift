//
//  AskForReviewUtil.swift
//  EncameraCore
//
//  Created by Alexander Freas on 27.01.23.
//

import Foundation
import StoreKit
import UIKit

public class AskForReviewUtil {

    public static var reviewURL: URL {
        return URL(string: AppConstants.appStoreURL)!.appending(queryItems: [URLQueryItem(name: "action", value: "write-review")])
    }

    public static func askForReviewIfNeeded() {
        // If the app doesn't store the count, this returns 0.
        var count = UserDefaultUtils.integer(forKey: .viewGalleryCount)

        count += 1
        
        UserDefaultUtils.set(count, forKey: .viewGalleryCount)
        
        // Keep track of the most recent app version that prompts the user for a review.
        let lastVersionPromptedForReview = UserDefaultUtils.string(forKey: .lastVersionReviewRequested)
        
        // Get the current bundle version for the app.
        let infoDictionaryKey = kCFBundleVersionKey as String
        guard let currentVersion = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        else { fatalError("Expected to find a bundle version in the info dictionary.") }
        // Verify the user completes the process several times and doesn’t receive a prompt for this app version.
        if count >= AppConstants.numberOfGalleryViewsBeforePromptingForReview && currentVersion != lastVersionPromptedForReview {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(2e9))
                
                await requestReview()
                
                UserDefaultUtils.set(currentVersion, forKey: .lastVersionReviewRequested)
            }
        }
    }

    @MainActor
    public static func requestReview() {
        guard let currentScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return
        }
        
        SKStoreReviewController.requestReview(in: currentScene)
    }



    @MainActor
    public static func openAppStoreReview() {
        UIApplication.shared.open(reviewURL, options: [:], completionHandler: nil)
    }
}
