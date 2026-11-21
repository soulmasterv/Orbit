import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var api: ServerAPI
    @State private var result = ""
    @AppStorage("appLock.v4") private var appLock = true
    @State private var lockChange = false
    @State private var lockChangeBusy = false
    @AppStorage("appearance.v2") private var appearance = AppAppearance.dark.rawValue

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    BrandMark(size: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Orbit").font(.title3.bold())
                        Text("Homelab Command Center").font(.caption).foregroundStyle(.secondary)
                        Text(OrbitBuildInfo().label)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
            }
            Section {
                NavigationLink {
                    ConnectionsView(api: api)
                } label: {
                    Label("Connections", systemImage: "network")
                }
                Text("Orbit / Classera · School Assistant")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Face ID app lock", isOn: Binding(get: { appLock }, set: { proposed in
                    if proposed { appLock = true } else { lockChange = true }
                })).disabled(lockChangeBusy)
                Text("When enabled, Face ID unlocks Orbit for five minutes, including app switching. The app stays visible during that session. With Face ID off, actions use confirmation only.").font(.caption).foregroundStyle(.secondary)
                if !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Security") }
              footer: { Text("Your bearer token stays in iOS Keychain, accessible only while the device is unlocked. Gemini, Meta and Discord credentials stay on Ubuntu.") }
            Section("Personalize") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in Text(option.title).tag(option.rawValue) }
                }
            }
            Section("App updates") {
                NavigationLink { OrbitChangelogView() } label: {
                    Label("What’s new", systemImage: "text.bubble")
                }
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
        .scrollContentBackground(.hidden).background(Brand.background)
        .onChange(of: api.accessAllowed) { _, allowed in
            if !allowed { lockChange = false }
        }
        .confirmationDialog("Disable app lock on this iPhone?", isPresented: $lockChange, titleVisibility: .visible) {
            Button("Disable app lock", role: .destructive) {
                lockChangeBusy = true
                Task {
                    defer { lockChangeBusy = false }
                    do { try await DeviceAuthorization.authorize(reason: "Disable the Orbit app lock on this iPhone."); appLock = false }
                    catch { result = DeviceAuthorization.isCancellation(error) ? "Cancelled. App lock remains enabled." : api.friendly(error) }
                }
            }
        } message: { Text("Server information will be visible without an app unlock prompt. Actions will require confirmation only.") }

    }
}





