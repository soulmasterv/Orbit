import SwiftUI

@main
struct ServerControlApp: App {
    init() { NotificationCleanup.removeLocalRegistration() }
    var body: some Scene {
        WindowGroup { AppRootView() }
    }
}


