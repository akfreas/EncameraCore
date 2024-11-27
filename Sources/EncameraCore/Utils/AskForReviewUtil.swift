///
//  AskForReviewUtil.swift
//  EncameraCore
//
//  Created by Alexander Freas on 27.01.23.
//

import Foundation
import StoreKit
import UIKit

public class AskForReviewUtil {

    private static var currentVersion: String? {
        let infoDictionaryKey = kCFBundleVersionKey as String
        return Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
    }

    public static var reviewURL: URL {
        return URL(string: AppConstants.appStoreURL)!.appending(queryItems: [URLQueryItem(name: "action", value: "write-review")])
    }

    public static func askForReviewIfNeeded(completion: @escaping (ReviewSelection) -> Void) {


        // If the app doesn't store the count, this returns 0.
        var count = UserDefaultUtils.integer(forKey: .reviewRequestedMetric)

        count += 1

        UserDefaultUtils.set(count, forKey: .reviewRequestedMetric)

        // Keep track of the most recent app version that prompts the user for a review.
        let lastVersionPromptedForReview = UserDefaultUtils.string(forKey: .lastVersionReviewRequested)

        // Get the current bundle version for the app.
        guard let currentVersion else { fatalError("Expected to find a bundle version in the info dictionary.") }
#if DEBUG
        guard count % AppConstants.reviewRequestThreshold == 0 else { return }
        Task {
            await showReviewPrompt(currentVersion: currentVersion, completion: completion)
        }
        return
#endif
        // Verify the user completes the process several times and doesn’t receive a prompt for this app version.
        if count % AppConstants.reviewRequestThreshold == 0 && currentVersion != lastVersionPromptedForReview {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(2e9))
                await showReviewPrompt(currentVersion: currentVersion, completion: completion)
            }
        } else {
            debugPrint("Not showing review alert. Count: \(count), threshold: \(AppConstants.reviewRequestThreshold), current version: \(currentVersion), last version prompted: \(lastVersionPromptedForReview ?? "none")")
        }
    }

    @MainActor
    private static func showReviewPrompt(currentVersion: String, completion: @escaping (ReviewSelection) -> Void) {
        presentReviewAlert { selection in
            Task { @MainActor in
                handleReviewSelection(selection, currentVersion: currentVersion)
                completion(selection)
            }
        }
    }

    @MainActor
    private static func presentReviewAlert(completion: @escaping (ReviewSelection) -> Void) {
        guard let currentScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = currentScene.windows.first?.rootViewController else {
            return
        }

        let alert = UIAlertController(title: L10n.AskForReview.enjoyingTheApp, message: nil, preferredStyle: .alert)

        let yesAction = UIAlertAction(title: L10n.yes, style: .default) { _ in
            completion(.yes)
        }

        let noAction = UIAlertAction(title: L10n.no, style: .default) { _ in
            completion(.no)
        }

        let askMeLaterAction = UIAlertAction(title: L10n.AskForReview.askMeLater, style: .default) { _ in
            completion(.askMeLater)
        }

        alert.addAction(yesAction)
        alert.addAction(noAction)
        alert.addAction(askMeLaterAction)

        UIApplication.topMostViewController()?.present(alert, animated: true, completion: nil)
    }

    @MainActor
    private static func handleReviewSelection(_ selection: ReviewSelection, currentVersion: String) {
        switch selection {
        case .yes:
            UserDefaultUtils.set(currentVersion, forKey: .lastVersionReviewRequested)
            EventTracking.trackReviewAlertYesPressed()
            requestReview()
        case .no:
            UserDefaultUtils.set(currentVersion, forKey: .lastVersionReviewRequested)
            EventTracking.trackReviewAlertNoPressed()
        case .askMeLater:
            EventTracking.trackReviewAlertAskLaterPressed()
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

    // Enum to represent the user's selection in the review alert
    public enum ReviewSelection {
        case yes
        case no
        case askMeLater
    }
}
