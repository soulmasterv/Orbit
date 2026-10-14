import SwiftUI
import Combine

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var message: String?
    private var generation = 0
    private var automaticUnlockPending = true
    private let authenticate: () async throws -> Void
    private let defaults: UserDefaults
    var lockEnabled: Bool { defaults.object(forKey: "appLock.v4") as? Bool ?? true }

    init(defaults: UserDefaults = .standard, authenticate: @escaping () async throws -> Void = {
        try await DeviceAuthorization.authorize(reason: "Unlock Orbit to view and manage your server.")
    }) {
        self.authenticate = authenticate
        self.defaults = defaults
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") &&
            !ProcessInfo.processInfo.arguments.contains("--preview-lock") {
            isUnlocked = true
            automaticUnlockPending = false
        }
        #endif
    }

    func activate() async {
        guard automaticUnlockPending else { return }
        await unlock()
    }

    func unlock() async {
        guard !isUnlocked && !isAuthenticating else { return }
        if !lockEnabled { isUnlocked = true; automaticUnlockPending = false; return }
        automaticUnlockPending = false
        isAuthenticating = true
        message = nil
        let attempt = generation
        defer { if generation == attempt { isAuthenticating = false } }
        do {
            try await authenticate()
            guard generation == attempt else { return }
            isUnlocked = true
        } catch {
            guard generation == attempt else { return }
            message = DeviceAuthorization.isCancellation(error) ? "Locked. Tap Unlock when you are ready." : error.localizedDescription
        }
    }

    func lock() {
        generation += 1
        isUnlocked = false
        isAuthenticating = false
        automaticUnlockPending = true
        message = nil
    }
}

struct AppRootView: View {
    @StateObject private var api = ServerAPI(accessAllowed: false, snapshotStore: DashboardSnapshotStore())
    @StateObject private var session = AppSession()
    @Environment(\.scenePhase) private var phase
    @State private var privacyCover = true

    var body: some View {
        ZStack {
            if session.isUnlocked {
                ContentView(api: api)
                    .disabled(privacyCover)
                    .accessibilityHidden(privacyCover)
            }
            if !session.isUnlocked || privacyCover {
                LockScreen(session: session, privacyOnly: session.isUnlocked)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.background.ignoresSafeArea())
                    .zIndex(1)
            }
        }
        .task { await activateIfNeeded() }
        .onChange(of: phase) { _, phase in
            privacyCover = phase != .active
            if phase == .background {
                session.lock()
                DeviceAuthorization.cancelCurrentAuthentication()
                api.setAccessAllowed(false)
            } else if phase == .active {
                Task { await activateIfNeeded() }
            }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            let wasAllowed = api.accessAllowed
            api.setAccessAllowed(unlocked && phase == .active)
            if unlocked && phase == .active && !wasAllowed {
                Task { await api.refreshAll() }
            }
        }
    }

    private func activateIfNeeded() async {
        guard phase == .active else { return }
        privacyCover = false
        guard !api.accessAllowed else { return }
        await session.activate()
        guard phase == .active && session.isUnlocked && !api.accessAllowed else { return }
        api.setAccessAllowed(true)
        await api.refreshAll()
    }
}

struct LockScreen: View {
    @ObservedObject var session: AppSession
    var privacyOnly = false
    var body: some View {
        VStack(spacing: 24) {
            BrandMark(size: 80)
            Text("Orbit").font(.largeTitle.bold())
            Label("Your server stays private", systemImage: "lock.shield")
                .font(.subheadline).foregroundStyle(.secondary)
            if !privacyOnly {
                if session.isAuthenticating { ProgressView("Authenticating…") }
                else {
                    Button { Task { await session.unlock() } } label: {
                        Label("Unlock", systemImage: "faceid").font(.headline)
                            .padding(.horizontal, 28).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).tint(Brand.accent)
                }
                if let message = session.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Text("Use Face ID, Touch ID or your device passcode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(32)
    }
}

