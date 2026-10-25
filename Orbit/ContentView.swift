import SwiftUI

struct PendingCommand: Identifiable {
    enum Target { case process(Int), docker }
    let id = UUID()
    let name: String
    let target: Target
    let action: ServerAction
    var title: String { "\(action.title) \(name)?" }
    var detail: String {
        switch action {
        case .start: return "Start this service on your Ubuntu server. You will authorize with Face ID, Touch ID or your device passcode."
        case .restart: return "This will briefly interrupt the service. You will authorize with Face ID, Touch ID or your device passcode."
        case .stop: return "This service will stop running until started again. You will authorize with Face ID, Touch ID or your device passcode."
        }
    }
}
enum DetailRoute: Hashable {
    case process(Int), docker(String), service(ServicePage), logs(LogTarget, String)
}

struct ContentView: View {
    @ObservedObject private var mobile: MobileStore
    @ObservedObject var api: ServerAPI
    @State private var pending: PendingCommand?
    @State private var selectedTab = ContentView.initialTab
    @State private var homePath: [DetailRoute] = []
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance.v2") private var appearance = AppAppearance.system.rawValue

    init(api: ServerAPI, initialTab: Int? = nil, initialDestination: DetailRoute? = nil, mobile: MobileStore? = nil) {
        self.api = api
        self.mobile = mobile ?? MobileStore(api: api)
        _selectedTab = State(initialValue: initialTab ?? Self.initialTab)
        _homePath = State(initialValue: initialDestination.map { [$0] } ?? [])
    }

    private static var initialTab: Int {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview-pm2") { return 1 }
        if arguments.contains("--preview-services") { return 3 }
        if arguments.contains("--preview-docker") { return 2 }
        if arguments.contains("--preview-settings") { return 4 }
        #endif
        return 3
    }

    private var colorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--dark-preview") { return .dark }
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") { return .light }
        #endif
        return AppAppearance(rawValue: appearance)?.scheme
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                HomeView(api: api, requestCommand: { pending = $0 })
                    .navigationDestination(for: DetailRoute.self) { route in
                        switch route {
                        case .process(let id): ProcessDetailView(api: api, processID: id, requestCommand: { pending = $0 })
                        case .docker(let name): ContainerDetailView(api: api, containerName: name, requestCommand: { pending = $0 })
                        case .service(let page): ServiceDetailView(api: api, page: page)
                        case .logs(let target, let name): LogViewer(api: api, target: target, name: name)
                        }
                    }
            }
                .tabItem { Label("Home", systemImage: "square.grid.2x2") }
                .tag(0)
            NavigationStack { ProcessesView(api: api, requestCommand: { pending = $0 }) }
                .tabItem { Label("PM2", systemImage: "terminal") }
                .tag(1)
            NavigationStack { ContainersView(api: api, requestCommand: { pending = $0 }) }
                .tabItem { Label("Docker", systemImage: "shippingbox") }
                .tag(2)
            NavigationStack {
                StudentDatabasesView(api: api)
                    .toolbar(.hidden, for: .tabBar)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button("Workspace", systemImage: "square.grid.2x2") { selectedTab = 0 }
                    } }
            }
                .tabItem { Label("Students", systemImage: "person.3") }
                .tag(3)
            NavigationStack { SettingsView(api: api) }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
        .environmentObject(api.library)
        .environmentObject(mobile)
        .tint(Brand.accent)
        .preferredColorScheme(colorScheme)
        .onChange(of: scenePhase) { _, value in
            if value == .background { selectedTab = 3; homePath = [] }
        }
        .confirmationDialog(pending?.title ?? "Confirm command",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible, presenting: pending) { command in
                Button(command.action.title, role: command.action == .stop ? .destructive : nil) {
                    Task {
                        switch command.target {
                        case .process(let id): await api.processAction(id: id, name: command.name, action: command.action)
                        case .docker: await api.dockerAction(name: command.name, action: command.action)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { command in Text(command.detail) }
        .alert("Command not completed",
               isPresented: Binding(get: { api.actionError != nil }, set: { if !$0 { api.actionError = nil } })) {
            Button("OK", role: .cancel) { api.actionError = nil }
        } message: { Text(api.actionError ?? "") }
        .safeAreaInset(edge: .top, spacing: 0) {
            if api.actionBusy {
                HStack(spacing: 12) {
                    ProgressView().tint(Brand.accent)
                    Text(api.actionProgress).font(.subheadline.weight(.medium))
                }
                .font(.caption).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8).allowsHitTesting(false)
                .shadow(color: .black.opacity(0.1), radius: 20, y: 8)
                .accessibilityElement(children: .combine)
            }
        }
    }
}



