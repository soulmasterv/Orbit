import SwiftUI

struct ConnectionsView: View {
    @ObservedObject var api: ServerAPI
    @State private var serverURL = ""
    @State private var token = ""
    @State private var result = ""
    @State private var testing = false
    @State private var removeConfirmation = false

    var body: some View {
        Form {
            Section {
                TextField("HTTPS server URL", text: $serverURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityLabel("Server URL")
                SecureField(api.hasSavedToken ? "Replace saved token (optional)" : "Server token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Server token")
                LabeledContent("Connection", value: api.connection.title)
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
                Button("Remove Orbit token", role: .destructive) { removeConfirmation = true }
                    .disabled(!api.hasSavedToken || api.loading || api.actionBusy || testing)
                if !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Orbit & Classera") }
              footer: { Text("Use your HTTPS Orbit address. Save only an address you trust: your bearer token will be sent there. Automatic Tailscale fallback applies only to the default production server. Leave the token field blank to keep your saved token.") }
            SchoolAssistantConnectionSection(api: api)
        }
        .navigationTitle("Connections").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(Brand.background)
        .onAppear { serverURL = api.baseURL }
        .onDisappear { token = "" }
        .onChange(of: api.accessAllowed) { _, allowed in
            if !allowed { token = ""; removeConfirmation = false }
        }
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
