import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var api: ServerAPI
    @State private var serverURL = ""
    @State private var token = ""
    @State private var result = ""
    @State private var testing = false
    @State private var removeConfirmation = false
    @AppStorage("appLock.v4") private var appLock = true
    @State private var lockChange = false
    @State private var lockChangeBusy = false
    @AppStorage("appearance.v2") private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    BrandMark(size: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Orbit").font(.title3.bold())
                        Text("Homelab Command Center").font(.caption).foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.0.0") • Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
            }
            Section {
                TextField("HTTPS server URL", text: $serverURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityLabel("Server URL")
                SecureField(api.hasSavedToken ? "Replace saved token (optional)" : "Server token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Server token")
                LabeledContent("Connection", value: api.connection.title)
                LabeledContent("Fallback", value: api.activeBaseURL == ServerAPI.fallbackBaseURL ? "Active" : (api.baseURL == ServerAPI.defaultBaseURL ? "Automatic if unreachable" : "Off for custom servers"))
                LabeledContent("Token", value: api.hasSavedToken ? "Saved in Keychain" : "Not configured")
                    .font(.subheadline)
                Button("Save & connect") {
                    do {
                        try api.saveConnection(url: serverURL, replacementToken: token)
                        token = ""
                        result = "Saved securely. Connecting…"
                        Task {
                            await api.loadDashboard()
                            result = api.connection == .connected ? "Connected. Your dashboard is up to date." : (api.errorMessage ?? "Add a token to connect.")
                        }
                    } catch { result = api.friendly(error) }
                }.disabled(api.loading || api.actionBusy || testing)
                Button {
                    testing = true
                    Task {
                        defer { testing = false }
                        do {
                            let health = try await api.healthCheck()
                            result = health.ok ? "Saved server is reachable. This public health check does not verify your token." : "Saved server reports a health issue."
                        } catch { result = api.friendly(error) }
                    }
                } label: {
                    HStack {
                        Text("Test Connection")
                        if testing { Spacer(); ProgressView() }
                    }
                }.disabled(testing || api.loading || api.actionBusy)
                if !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Server connection") }
              footer: { Text("Use your HTTPS Orbit address. Save only an address you trust: your bearer token will be sent there. Automatic Tailscale fallback applies only to the default production server. Leave the token field blank to keep your saved token.") }
            Section {
                Toggle("Face ID app lock", isOn: Binding(get: { appLock }, set: { proposed in
                    if proposed { appLock = true } else { lockChange = true }
                })).disabled(lockChangeBusy)
                Text("When enabled, Face ID unlocks Orbit for five minutes, including app switching. The app stays visible during that session. Sensitive actions still require device authentication.").font(.caption).foregroundStyle(.secondary)
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Protected server controls").font(.subheadline.bold())
                        Text("With app lock enabled, authenticate once for a five-minute session. Returning after that session expires requires authentication. Every command needs confirmation and Face ID, Touch ID or your device passcode. Without a device passcode, commands remain locked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "lock.shield").foregroundStyle(Brand.teal) }
                Button("Remove saved token", role: .destructive) { removeConfirmation = true }
                    .disabled(!api.hasSavedToken || api.loading || api.actionBusy || testing)
            } header: { Text("Security") }
              footer: { Text("Your bearer token stays in iOS Keychain, accessible only while the device is unlocked. Gemini, Meta and Discord credentials stay on Ubuntu.") }
            Section("Personalize") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in Text(option.title).tag(option.rawValue) }
                }
            }
            Section("Students") {
                NavigationLink {
                    StudentsSettingsView(api: api)
                } label: {
                    Label("Students connection", systemImage: "person.3")
                }
                Text("The Students base URL and API key are stored together in Keychain. Management requires a compatible backend and device authorization.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                LabeledContent("Primary server", value: api.baseURL).font(.caption).textSelection(.enabled)
                LabeledContent("Active server", value: api.activeBaseURL).font(.caption).textSelection(.enabled)
                LabeledContent("Last snapshot", value: api.lastUpdated.map { HumanTime.label($0) } ?? "Not available")
                if let network = api.lastNetworkSeconds { LabeledContent("Network", value: String(format: "%.2f s", network)) }
                if let decode = api.lastDecodeSeconds { LabeledContent("Decode", value: String(format: "%.3f s", decode)) }
                Text("Refreshes share one in-flight request. Pull to refresh; returning to the foreground refreshes once.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Distribution", value: "SideStore")
                LabeledContent("Minimum iOS", value: "17")
                Text("Service status comes from your authenticated Orbit backend.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("About") }
        }
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            serverURL = api.baseURL
        }
        .onDisappear { token = "" }
        .confirmationDialog("Disable app lock on this iPhone?", isPresented: $lockChange, titleVisibility: .visible) {
            Button("Disable app lock", role: .destructive) {
                lockChangeBusy = true
                Task {
                    defer { lockChangeBusy = false }
                    do { try await DeviceAuthorization.authorize(reason: "Disable the Orbit app lock on this iPhone."); appLock = false }
                    catch { result = DeviceAuthorization.isCancellation(error) ? "Cancelled. App lock remains enabled." : api.friendly(error) }
                }
            }
        } message: { Text("Server information will be visible without an app unlock prompt. Commands will still require confirmation and authentication.") }
        .confirmationDialog("Remove the saved token?", isPresented: $removeConfirmation, titleVisibility: .visible) {
            Button("Remove token", role: .destructive) {
                Task {
                    do {
                        try await DeviceAuthorization.authorize(reason: "Remove the saved Orbit token.")
                        try api.removeToken()
                        token = ""
                        result = "Token removed from this iPhone."
                    } catch {
                        result = DeviceAuthorization.isCancellation(error) ? "Cancelled. Token was kept." : api.friendly(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This disconnects the app. It does not change or revoke the token on Ubuntu.") }
    }
}




