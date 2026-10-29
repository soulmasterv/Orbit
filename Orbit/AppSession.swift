import SwiftUI
import Combine

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var message: String?
    private var generation = 0
    private var automaticUnlockPending = true
    private var unlockedAt: TimeInterval?
    private let uptime: () -> TimeInterval
    static let unlockLifetime: TimeInterval = 300
    var remainingUnlockTime: TimeInterval? {
        guard lockEnabled, let unlockedAt else { return nil }
        return max(0, Self.unlockLifetime - max(0, uptime() - unlockedAt))
    }
    func expireIfNeeded() {
        if isUnlocked, let remainingUnlockTime, remainingUnlockTime <= 0 { lock() }
    }
    private let authenticate: () async throws -> Void
    private let defaults: UserDefaults
    var lockEnabled: Bool { defaults.object(forKey: "appLock.v4") as? Bool ?? true }

    init(defaults: UserDefaults = .standard, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, authenticate: @escaping () async throws -> Void = {
        try await DeviceAuthorization.authorize(reason: "Unlock Orbit to view and manage your server.")
    }) {
        self.authenticate = authenticate
        self.defaults = defaults
        self.uptime = uptime
        if !lockEnabled { isUnlocked = true; automaticUnlockPending = false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") &&
            !ProcessInfo.processInfo.arguments.contains("--preview-lock") {
            isUnlocked = true
            automaticUnlockPending = false
        }
        #endif
    }

    func activate() async {
        expireIfNeeded()
        guard automaticUnlockPending else { return }
        await unlock()
    }

    func unlock() async {
        expireIfNeeded()
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
            unlockedAt = uptime()
            isUnlocked = true
        } catch {
            guard generation == attempt else { return }
            message = DeviceAuthorization.isCancellation(error) ? "Locked. Tap Unlock when you are ready." : error.localizedDescription
        }
    }

    func lock() {
        generation += 1
        unlockedAt = nil
        isUnlocked = false
        isAuthenticating = false
        automaticUnlockPending = true
        message = nil
    }
}

struct AppRootView: View {
    @StateObject private var api: ServerAPI
    @StateObject private var mobile: MobileStore
    @StateObject private var session = AppSession()
    @Environment(\.scenePhase) private var phase
    @State private var privacyCover = false

    init() {
        let api = ServerAPI(accessAllowed: false, snapshotStore: DashboardSnapshotStore())
        _api = StateObject(wrappedValue: api)
        _mobile = StateObject(wrappedValue: MobileStore(api: api))
    }

    var body: some View {
        RetainedProtectedContent(visible: session.isUnlocked && !privacyCover) {
            ContentView(api: api, mobile: mobile)
                .environmentObject(mobile)
        } cover: {
            if session.lockEnabled {
                LockScreen(session: session, privacyOnly: session.isUnlocked)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.background.ignoresSafeArea())
            }
        }
        .task { await activateIfNeeded() }
        .task(id: session.isUnlocked) {
            guard session.isUnlocked, let remaining = session.remainingUnlockTime else { return }
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            session.expireIfNeeded()
        }
        .task(id: phase == .active && api.accessAllowed) {
            guard phase == .active && api.accessAllowed else { return }
            await mobile.refresh()
            await mobile.retireNotifications()
            await mobile.boundedRecovery()
        }
        .onChange(of: phase) { _, phase in
            session.expireIfNeeded()
            privacyCover = phase != .active && !session.isUnlocked
            if phase == .background {
                DeviceAuthorization.cancelCurrentAuthentication()
                api.setAccessAllowed(false)
                mobile.suspend()
            } else if phase == .active {
                Task { await activateIfNeeded() }
            }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { DeviceAuthorization.cancelCurrentAuthentication() }
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
        session.expireIfNeeded()
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
            Text(OrbitBuildInfo().label).font(.caption).foregroundStyle(.secondary)
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





