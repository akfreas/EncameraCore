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
                print("Local notification permissions granted.")
            } else if let error = error {
                print("Error requesting local notification permissions: \(error)")
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
                print("Error requesting remote notification permissions: \(error)")
            }
        }
    }

    public class func scheduleNotificationForPremiumReminder() {
        scheduleNotification(identifier: "premiumReminder", title: "20% Discount - Limited time 📅", body: "Use code 'ENCAMERA20' to get a 20% discount on any plan. Hurry up!", delay: oneDayInSeconds)
    }

    public class func scheduleNotificationForImageSaveReminder() {
        scheduleNotification(identifier: "imageSaveReminder", title: "We would like your support 🙏", body: "Hope you like Encamera - This is why we need you to help us with a review. Tap here!", delay: oneDayInSeconds)
    }

    public class func scheduleNotificationForImageSecurityReminder() {
        scheduleNotification(identifier: "imageSecurityReminder", title: "Did you know? 🤔", body: "You can also save videos to your albums, not only images. Try it now and secure some!", delay: oneDayInSeconds)
    }

    public class func scheduleNotificationForInactiveUserReminder() {
        scheduleNotification(identifier: "inactiveUserReminder", title: "Your images might be at risk 🚨", body: "Don’t forget to secure more images by adding them to your album. Import now!", delay: threeDaysInSeconds)
    }

    public class func scheduleNotificationForWidgetReminder() {
        scheduleNotification(identifier: "widgetReminder", title: "Take directly encrypted photos 📸", body: "Don’t forget to add the widget on the lock screen and take images quickly. See how!", delay: oneDayInSeconds)
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
            print("Unknown notification identifier")
        }
    }

    public class func handlePremiumReminder() {
        // Navigate to premium plan purchase page
        print("Navigating to the premium plan purchase page.")
    }

    public class func handleImageSaveReminder() {
        // Navigate to review submission page
        print("Navigating to the review submission page.")
    }

    public class func handleImageSecurityReminder() {
        // Show educational content about saving videos
        print("Showing educational content on how to save videos.")
    }

    public class func handleInactiveUserReminder() {
        // Prompt user to import images to secure them
        print("Prompting user to import more images for security.")
    }

    public class func handleWidgetReminder() {
        // Guide user to add widget to lock screen
        print("Guiding user to add a widget to the lock screen.")
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
                print("Error scheduling notification: \(error)")
            }
        }
    }

    private class func cancelScheduledNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
