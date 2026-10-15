import SwiftUI

@main
struct ServerControlApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate
    init() { _ = NotificationManager.shared }
    var body: some Scene {
        WindowGroup { AppRootView() }
    }
}

