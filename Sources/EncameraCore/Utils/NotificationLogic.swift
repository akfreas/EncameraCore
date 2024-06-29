import Foundation

public class NotificationLogic {

    static public func setNotificationsForMediaAdded() {
        Task { @MainActor in
            if ((try? await NotificationManager.requestLocalNotificationPermission()) != nil) {
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
