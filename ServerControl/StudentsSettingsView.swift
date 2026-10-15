import SwiftUI

struct StudentsSettingsView: View {
    @EnvironmentObject private var mobile: MobileStore
    @ObservedObject var api: ServerAPI
    @State private var baseURL = ""
    @State private var replacementKey = ""
    @State private var hasSavedKey = false
    @State private var result: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("HTTPS base URL", text: $baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Students HTTPS base URL")
                SecureField(hasSavedKey ? "Replace API key (optional)" : "API key", text: $replacementKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Students API key")
                LabeledContent("API key", value: hasSavedKey ? "Saved in Keychain" : "Not configured")
                Button("Save Students Connection") { Task { await save() } }.disabled(!api.accessAllowed || saving)
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Students connection") }
              footer: {
                  Text("Enter the base URL only; the app adds /api/students. Both the URL and API key are kept in Keychain on this iPhone. Save only a server you trust. Leave the key blank to keep its current value when the URL is unchanged.")
              }
            Section {
                NavigationLink("Students notifications & saved messages") { MobileHubView(api: api) }
                Text("Management and manual messages require a compatible backend. Existing push registration must be revoked before changing the Students server or account. Review any saved message operation first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Students Connection").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do {
                let saved = try KeychainManager.loadStudentsConnection()
                baseURL = saved?.baseURL ?? ""
                hasSavedKey = saved?.apiKey.isEmpty == false
            } catch { result = StudentsStore.message(for: error) }
        }
        .onDisappear { replacementKey = "" }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let url = try ServerAPI.validatedBaseURL(baseURL).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let saved = try KeychainManager.loadStudentsConnection()
            let key = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // Do not forward an existing secret to a newly entered destination.
            guard !key.isEmpty || url == saved?.baseURL else {
                throw APIError.message("Enter the API key again when changing the Students server URL.")
            }
            let next = try StudentsConnection(baseURL: url, apiKey: key.isEmpty ? (saved?.apiKey ?? "") : key).validated()
            if next != saved { try await mobile.prepareConnectionChange() }
            guard api.accessAllowed else { throw CancellationError() }
            try KeychainManager.saveStudentsConnection(next)
            baseURL = url
            replacementKey = ""
            hasSavedKey = true
            result = "Saved securely. Open Students to refresh the directory."
        } catch { result = StudentsStore.message(for: error) }
    }
}


