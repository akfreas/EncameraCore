import UIKit
import UserNotifications

public enum NotificationIdentifier: String {
    case premiumReminder
    case leaveAReviewReminder
    case imageSecurityReminder
    case inactiveUserReminder
    case widgetReminder
}

public class NotificationManager {

    class func seconds(forDays days: Int) -> TimeInterval {
        #if DEBUG
        return 20
        #else
        return TimeInterval(days) * 24 * 60 * 60
        #endif
    }

    public class func requestLocalNotificationPermission() async throws -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await MainActor.run {
                if granted {
                    EventTracking.trackNotificationPermissionsGranted()
                } else {
                    EventTracking.trackNotificationPermissionsDenied()
                }
            }
            return granted
        }
        return settings.authorizationStatus == .authorized
    }

    public class func scheduleNotificationForPremiumReminder() {
        scheduleNotification(identifier: .premiumReminder, title: L10n.Notification.PremiumReminder.title, body: L10n.Notification.PremiumReminder.body, delay: seconds(forDays: 1))
    }

    public class func scheduleNotificationForLeaveReviewReminder() {
        scheduleNotification(identifier: .leaveAReviewReminder, title: L10n.Notification.ImageSaveReminder.title, body: L10n.Notification.ImageSaveReminder.body, delay: seconds(forDays: 4))
    }

    public class func scheduleNotificationForImageSecurityReminder() {
        scheduleNotification(identifier: .imageSecurityReminder, title: L10n.Notification.ImageSecurityReminder.title, body: L10n.Notification.ImageSecurityReminder.body, delay: seconds(forDays: 1))
    }

    public class func scheduleNotificationForInactiveUserReminder() {
        scheduleNotification(identifier: .inactiveUserReminder, title: L10n.Notification.InactiveUserReminder.title, body: L10n.Notification.InactiveUserReminder.body, delay: seconds(forDays: 3))
    }

    public class func scheduleNotificationForWidgetReminder() {
        scheduleNotification(identifier: .widgetReminder, title: L10n.Notification.WidgetReminder.title, body: L10n.Notification.WidgetReminder.body, delay: seconds(forDays: 2))
    }

    public class func cancelNotificationForPremiumReminder() {
        cancelScheduledNotification(identifier: .premiumReminder)
    }

    public class func cancelNotificationForLeaveReviewReminder() {
        cancelScheduledNotification(identifier: .leaveAReviewReminder)
    }

    public class func cancelNotificationForImageSecurityReminder() {
        cancelScheduledNotification(identifier: .imageSecurityReminder)
    }

    public class func cancelNotificationForInactiveUserReminder() {
        cancelScheduledNotification(identifier: .inactiveUserReminder)
    }

    public class func cancelNotificationForWidgetReminder() {
        cancelScheduledNotification(identifier: .widgetReminder)
    }

    public class func handleNotificationOpen(with identifier: String) {
        guard let notificationIdentifier = NotificationIdentifier(rawValue: identifier) else {
            print(L10n.Notification.unknownIdentifier)
            return
        }

        switch notificationIdentifier {
        case .premiumReminder:
            handlePremiumReminder()
        case .leaveAReviewReminder:
            handleLeaveAReviewReminder()
        case .imageSecurityReminder:
            handleImageSecurityReminder()
        case .inactiveUserReminder:
            handleInactiveUserReminder()
        case .widgetReminder:
            handleWidgetReminder()
        }
    }

    private class func handlePremiumReminder() {
        if let url = URL(string: "https://apps.apple.com/redeem?ctx=offercodes&id=1639202616&code=ENCAMERA20") {
            UIApplication.shared.open(url)
        }
    }

    private class func handleLeaveAReviewReminder() {
        Task { @MainActor in
            AskForReviewUtil.openAppStoreReview()
        }
    }

    private class func handleImageSecurityReminder() {
        print(L10n.Notification.VideoSave.educationalContent)
    }

    private class func handleInactiveUserReminder() {
        print(L10n.Notification.ImportImages.prompt)
    }

    private class func handleWidgetReminder() {
        print(L10n.Notification.WidgetSetup.guidance)
    }

    private class func scheduleNotification(identifier: NotificationIdentifier, title: String, body: String, delay: TimeInterval) {
        cancelScheduledNotification(identifier: identifier)
        UserDefaultUtils.increaseInteger(forKey: .notificationScheduledCount(identifier: identifier))
        debugPrint("Scheduling notification for \(identifier.rawValue) in \(delay) seconds")
        debugPrint("Count for identifier is \(UserDefaultUtils.integer(forKey: .notificationScheduledCount(identifier: identifier)))")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier.rawValue, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print(L10n.Notification.Scheduling.error(error.localizedDescription))
            }
        }
    }

    private class func cancelScheduledNotification(identifier: NotificationIdentifier) {
        debugPrint("Cancelling notification for \(identifier.rawValue)")
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier.rawValue])
    }
}
