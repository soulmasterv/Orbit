import UIKit
import UserNotifications

// One-way upgrade cleanup. The app no longer requests permission, registers an
// APNs token, schedules local notifications or installs a notification delegate.
@MainActor
enum NotificationCleanup {
    static func removeLocalRegistration() {
        UIApplication.shared.unregisterForRemoteNotifications()
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        UserDefaults.standard.removeObject(forKey: "alerts.preferences.v2")
    }
}
