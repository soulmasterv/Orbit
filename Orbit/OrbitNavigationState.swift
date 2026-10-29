import SwiftUI

/// Presentation state only, held in memory. Never persisted to UserDefaults or logs.
@MainActor
final class OrbitNavigationState: ObservableObject {
    @Published var selectedTab: Int
    @Published var homePath: NavigationPath
    @Published var processesPath = NavigationPath()
    @Published var containersPath = NavigationPath()
    @Published var studentsPath = NavigationPath()
    @Published var settingsPath = NavigationPath()
    private var anchors: [String: String] = [:]
    init(selectedTab: Int = 3, home: [DetailRoute] = []) {
        self.selectedTab = selectedTab; homePath = NavigationPath(home)
    }
    func anchor(for screen: String) -> String? { anchors[screen] }
    func remember(_ anchor: String?, for screen: String) {
        // Privacy cleanup can temporarily remove scroll targets. Do not replace a
        // useful anchor with nil; it will become available after a verified refresh.
        if let anchor { anchors[screen] = anchor }
    }
}

struct ClasseraStudentRoute: Hashable { let phone: String }
struct SchoolStudentRoute: Hashable { let phone: String }
private struct OrbitNavigationKey: EnvironmentKey {
    static let defaultValue: OrbitNavigationState? = nil
}
private struct OrbitAccessPresentationKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    /// Presentation cleanup only. ServerAPI retains its own authorization checks.
    var orbitAccessAllowed: Bool {
        get { self[OrbitAccessPresentationKey.self] }
        set { self[OrbitAccessPresentationKey.self] = newValue }
    }
    var orbitNavigation: OrbitNavigationState? {
        get { self[OrbitNavigationKey.self] }
        set { self[OrbitNavigationKey.self] = newValue }
    }
}

/// Keeps view identity/navigation alive while all content is visually and
/// accessibly hidden behind the existing lock UI. This never authorizes an API.
struct RetainedProtectedContent<Content: View, Cover: View>: View {
    let visible: Bool
    let content: Content
    let cover: Cover
    init(visible: Bool, @ViewBuilder content: () -> Content, @ViewBuilder cover: () -> Cover) {
        self.visible = visible; self.content = content(); self.cover = cover()
    }
    var body: some View {
        ZStack {
            content.opacity(visible ? 1 : 0)
                .disabled(!visible).allowsHitTesting(visible).accessibilityHidden(!visible)
            if !visible { cover.frame(maxWidth: .infinity, maxHeight: .infinity).zIndex(1) }
        }
    }
}
