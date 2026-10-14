import SwiftUI

struct StudentsSettingsView: View {
    @ObservedObject var api: ServerAPI
    @State private var baseURL = ""
    @State private var replacementKey = ""
    @State private var hasSavedKey = false
    @State private var result: String?

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
                Button("Save Students Connection") { save() }.disabled(!api.accessAllowed)
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Students connection") }
              footer: {
                  Text("Enter the base URL only; the app adds /api/students. Both the URL and API key are kept in Keychain on this iPhone. Save only a server you trust. Leave the key blank to keep its current value when the URL is unchanged.")
              }
            Section {
                Text("V1 is read-only. The app cannot send messages, edit students or delete records.")
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

    private func save() {
        do {
            let url = try ServerAPI.validatedBaseURL(baseURL).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let saved = try KeychainManager.loadStudentsConnection()
            let key = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // Do not forward an existing secret to a newly entered destination.
            guard !key.isEmpty || url == saved?.baseURL else {
                throw APIError.message("Enter the API key again when changing the Students server URL.")
            }
            try KeychainManager.saveStudentsConnection(StudentsConnection(baseURL: url, apiKey: key.isEmpty ? (saved?.apiKey ?? "") : key))
            baseURL = url
            replacementKey = ""
            hasSavedKey = true
            result = "Saved securely. Open Students to refresh the directory."
        } catch { result = StudentsStore.message(for: error) }
    }
}
