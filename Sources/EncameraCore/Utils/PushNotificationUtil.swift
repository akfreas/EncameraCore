import UIKit
import UserNotifications

public class NotificationManager {

    class var oneDayInSeconds: TimeInterval {
        #if DEBUG
        return 20
        #else
        return 24 * 60 * 60
        #endif
    }

    class var threeDaysInSeconds: TimeInterval {
        #if DEBUG
        return 20
        #else
        return 3 * oneDayInSeconds
        #endif
    }

    public class func requestLocalNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    Task { @MainActor in
                        if granted {
                            EventTracking.trackNotificationPermissionsGranted()
                        } else if let error = error {
                            print(L10n.Notification.Permission.error(error.localizedDescription))
                        } else {
                            EventTracking.trackNotificationPermissionsDenied()
                        }
                    }
                }
            }
        }
    }


    public class func scheduleNotificationForPremiumReminder() {
        scheduleNotification(identifier: "premiumReminder", title: L10n.Notification.PremiumReminder.title, body: L10n.Notification.PremiumReminder.body, delay: oneDayInSeconds)
    }

    public class func scheduleNotificationForImageSaveReminder() {
        scheduleNotification(identifier: "imageSaveReminder", title: L10n.Notification.ImageSaveReminder.title, body: L10n.Notification.ImageSaveReminder.body, delay: oneDayInSeconds)
    }

    public class func scheduleNotificationForImageSecurityReminder() {
        scheduleNotification(identifier: "imageSecurityReminder", title: L10n.Notification.ImageSecurityReminder.title, body: L10n.Notification.ImageSecurityReminder.body, delay: oneDayInSeconds)
    }

    public class func scheduleNotificationForInactiveUserReminder() {
        scheduleNotification(identifier: "inactiveUserReminder", title: L10n.Notification.InactiveUserReminder.title, body: L10n.Notification.InactiveUserReminder.body, delay: threeDaysInSeconds)
    }

    public class func scheduleNotificationForWidgetReminder() {
        scheduleNotification(identifier: "widgetReminder", title: L10n.Notification.WidgetReminder.title, body: L10n.Notification.WidgetReminder.body, delay: oneDayInSeconds)
    }

    public class func cancelNotificationForPremiumReminder() {
        cancelScheduledNotification(identifier: "premiumReminder")
    }

    public class func cancelNotificationForImageSaveReminder() {
        cancelScheduledNotification(identifier: "imageSaveReminder")
    }

    public class func cancelNotificationForImageSecurityReminder() {
        cancelScheduledNotification(identifier: "imageSecurityReminder")
    }

    public class func cancelNotificationForInactiveUserReminder() {
        cancelScheduledNotification(identifier: "inactiveUserReminder")
    }

    public class func cancelNotificationForWidgetReminder() {
        cancelScheduledNotification(identifier: "widgetReminder")
    }

    public class func handleNotificationOpen(with identifier: String) {
        switch identifier {
        case "premiumReminder":
            handlePremiumReminder()
        case "imageSaveReminder":
            handleImageSaveReminder()
        case "imageSecurityReminder":
            handleImageSecurityReminder()
        case "inactiveUserReminder":
            handleInactiveUserReminder()
        case "widgetReminder":
            handleWidgetReminder()
        default:
            print(L10n.Notification.unknownIdentifier)
        }
    }

    public class func handlePremiumReminder() {
        if let url = URL(string: "https://apps.apple.com/redeem?ctx=offercodes&id=1639202616&code=ENCAMERA20") {
            UIApplication.shared.open(url)
        }
    }

    public class func handleImageSaveReminder() {
        print(L10n.Notification.ReviewPage.navigation)
    }

    public class func handleImageSecurityReminder() {
        print(L10n.Notification.VideoSave.educationalContent)
    }

    public class func handleInactiveUserReminder() {
        print(L10n.Notification.ImportImages.prompt)
    }

    public class func handleWidgetReminder() {
        print(L10n.Notification.WidgetSetup.guidance)
    }

    private class func scheduleNotification(identifier: String, title: String, body: String, delay: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print(L10n.Notification.Scheduling.error(error.localizedDescription))
            }
        }
    }

    private class func cancelScheduledNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
