import SwiftUI

@main
struct OrbitApp: App {
    init() { NotificationCleanup.removeLocalRegistration() }
    var body: some Scene {
        WindowGroup { AppRootView() }
    }
}


