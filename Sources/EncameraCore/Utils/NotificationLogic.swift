import Foundation

public class NotificationLogic {

    static public var shouldAskForNotificationPermissions: Bool {
        get async {

            guard UserDefaultUtils.bool(forKey: .showPushNotificationPrompt) else {
                return false
            }
            guard await NotificationManager.isNotDetermined else {
                return false
            }

            if UserDefaultUtils.integer(forKey: .videoAddedCount) >= 3
                || UserDefaultUtils.integer(forKey: .photoAddedCount) >= 3
                || UserDefaultUtils.integer(forKey: .capturedPhotos) >= 3 {
                return true
            }
            return false
        }
    }

    static public func setNotificationsForMediaAdded() {
        Task { @MainActor in
            if (await NotificationManager.isAuthorized) {
                if UserDefaultUtils.integer(forKey: .videoAddedCount) == 0
                    && UserDefaultUtils.integer(forKey: .photoAddedCount) > 5
                    && UserDefaultUtils.integer(forKey: .notificationScheduledCount(identifier: .imageSecurityReminder)) == 0 {
                    NotificationManager.cancelNotificationForInactiveUserReminder()
                    NotificationManager.scheduleNotificationForImageSecurityReminder()
                } else if UserDefaultUtils.integer(forKey: .photoAddedCount) + UserDefaultUtils.integer(forKey: .videoAddedCount) > 6
                    && UserDefaultUtils.integer(forKey: .notificationScheduledCount(identifier: .leaveAReviewReminder)) == 0 {
                    NotificationManager.scheduleNotificationForLeaveReviewReminder()
                } else if UserDefaultUtils.integer(forKey: .photoAddedCount) + UserDefaultUtils.integer(forKey: .videoAddedCount) == 1 
                    && UserDefaultUtils.integer(forKey: .notificationScheduledCount(identifier: .inactiveUserReminder)) == 0 {
                    NotificationManager.scheduleNotificationForInactiveUserReminder()
                }
                if UserDefaultUtils.integer(forKey: .photoAddedCount) + UserDefaultUtils.integer(forKey: .videoAddedCount) > 2
                 && UserDefaultUtils.integer(forKey: .notificationScheduledCount(identifier: .widgetReminder)) < 2
                    && UserDefaultUtils.integer(forKey: .widgetOpenCount) == 0
                {
                    NotificationManager.scheduleNotificationForWidgetReminder()
                }
            }
        }
    }
}
