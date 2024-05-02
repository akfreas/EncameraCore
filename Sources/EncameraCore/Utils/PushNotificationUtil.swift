import UIKit
import UserNotifications

public class NotificationManager {

    class var oneDayInSeconds: TimeInterval {
        #if DEBUG
        return 60
        #else
        return 86400
        #endif
    }

    class var threeDaysInSeconds: TimeInterval {
        #if DEBUG
        return 60
        #else
        return 259200
        #endif
    }

    public class func requestLocalNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print(L10n.Notification.Permission.granted)
            } else if let error = error {
                print(L10n.Notification.Permission.error(error.localizedDescription))
            }
        }
    }

    public class func requestRemoteNotificationPermission(application: UIApplication) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            } else if let error = error {
                print(L10n.Notification.Permission.remoteError(error.localizedDescription))
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
        print(L10n.Notification.PremiumPage.navigation)
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
