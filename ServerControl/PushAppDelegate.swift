import UIKit

final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in NotificationManager.shared.apnsToken = token; NotificationManager.shared.remoteError = nil }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            NotificationManager.shared.remoteError = "APNs registration failed. Check this device's push-enabled signing profile and network. The event feed remains available."
        }
    }
}
