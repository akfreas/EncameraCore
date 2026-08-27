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
    public static let reviewRequestThreshold = 20
    public static let lowOpacity = 0.4
    public static let previewDirectory = "preview_thumbnails"
    public static let defaultPinCodeLength: PasscodeType.PasscodeLength = .four
    public static let lockoutTime: TimeInterval = 300
    public static let maxCharacterAlbumName = 20

    /// How long a fresh install quietly polls for iCloud Keychain credential
    /// arrival before committing to onboarding. Hidden behind the splash screen.
    public static let keychainRestoreQuietGrace: TimeInterval = 2.5
    /// How long the explicit "Restoring from iCloud…" screen polls before
    /// falling back to onboarding.
    public static let keychainRestoreWaitTimeout: TimeInterval = 20

    // Legacy accessors (prefer URLs enum)
    public static let appStoreURL = URLs.appStore.rawValue
    public static let widgetVimeoLink = URLs.widgetTutorialVideo.url
    public static let feedbackApiURL = URLs.feedbackApi.url

    // Supabase Edge Functions
//    #if DEBUG
//    public static var supabaseFunctionsBaseURL = "http://127.0.0.1:54321/functions/v1"
//    #else
    public static var supabaseFunctionsBaseURL = URLs.supabaseFunctionsBase.rawValue
//    #endif

    /// Centralized URL registry. Every external URL used in the app should be
    /// declared here so that we can enumerate and validate them.
    public enum URLs: String, CaseIterable {
        // App Store & Marketing
        case appStore = "https://apps.apple.com/us/app/encamera-encrypted-photo-vault/id1639202616"

        // Tutorials & Media
        case widgetTutorialVideo = "https://vimeo.com/896507875"

        // APIs & Backend (authenticated — require API keys or POST bodies)
        case feedbackApi = "https://script.google.com/macros/s/AKfycbwDkuMT5MkmfpBmaahRJhM7BVWCvBcALiC6cKIaanmNGggMrY7qn50EKV-ZeZS6miJO/exec"
        case supabaseFunctionsBase = "https://iwyaxywmukbescxoownb.supabase.co/functions/v1"
        case supabaseAnalyticsTrack = "https://iwyaxywmukbescxoownb.supabase.co/functions/v1/track"
        case appleAdsAttribution = "https://api-adservices.apple.com/api/v1/"

        // Website Pages
        case openSource = "https://encamera.app/open-source/"
        case privacyPolicy = "https://encamera.app/privacy/"
        case roadmap = "https://encamera.featurebase.app/"
        case promotionsConfig = "https://config.encamera.app/promotions/current.json"

        // Legal
        case appleEULA = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"

        // Social & Community
        case reddit = "https://www.reddit.com/r/encamera/"
        case telegram = "https://t.me/encamera_app"
        case discord = "https://discord.encamera.app/"
        case twitter = "https://x.com/encamera_app"

        // Promotional Assets (seasonal — may not always be live)
        case blackFridayHeaderImage = "https://encamera.app/assets/black-friday-main.png"
        case blackFridayTopLeft = "https://encamera.app/assets/bf-top-left.png"
        case blackFridayTopRight = "https://encamera.app/assets/bf-top-right.png"
        case blackFridayBottomLeft = "https://encamera.app/assets/bf-bottom-left.png"
        case blackFridayBottomRight = "https://encamera.app/assets/bf-bottom-right.png"

        /// Convenience accessor that returns `URL`.
        public var url: URL {
            URL(string: rawValue)!
        }

        /// URLs an anonymous request cannot get a trustworthy health answer
        /// out of. They are excluded from `publicCases`, so nothing probes them.
        ///
        /// A case belongs here when:
        ///
        /// - It needs credentials or a particular request body, so an anonymous
        ///   request's status says nothing about the endpoint: `feedbackApi`
        ///   answers 200 to any GET and invokes the script, the Supabase hosts
        ///   answer 401 without an API key, `appleAdsAttribution` answers 404
        ///   without an attribution body.
        /// - Its host serves browsers but deflects automated clients from
        ///   shared addresses. `twitter` and `reddit` answer 403 to any request
        ///   that is not a browser session, whatever user agent it presents;
        ///   `telegram` refuses the TLS handshake outright from CI runner
        ///   addresses while serving ordinary clients normally. A probe cannot
        ///   tell any of the three apart from a dead link, so it does not watch
        ///   them.
        /// - It is a seasonal promo asset that is not always published: the
        ///   `blackFriday*` cases under `encamera.app/assets/`.
        ///
        /// Everything else is public. `URLIntegrationTests` re-derives this
        /// classification from each case's host and path and fails if the list
        /// disagrees.
        public static let authenticated: Set<URLs> = [
            .feedbackApi,
            .supabaseFunctionsBase,
            .supabaseAnalyticsTrack,
            .appleAdsAttribution,
            .twitter,
            .reddit,
            .telegram,
            .blackFridayHeaderImage,
            .blackFridayTopLeft,
            .blackFridayTopRight,
            .blackFridayBottomLeft,
            .blackFridayBottomRight,
        ]

        public var isAuthenticated: Bool {
            Self.authenticated.contains(self)
        }

        /// URLs an unauthenticated request may expect a 2xx from, and the exact
        /// surface the live reachability probe watches. The complement of
        /// `authenticated`, whose doc comment carries the classification rule.
        public static var publicCases: [URLs] {
            allCases.filter { !$0.isAuthenticated }
        }
    }
}
