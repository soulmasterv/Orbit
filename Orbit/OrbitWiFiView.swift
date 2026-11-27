import SwiftUI

struct OrbitWiFiView: View {
    @ObservedObject var api: ServerAPI
    @State private var phone = ""
    @State private var directory: InternetTrackerDirectory?
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    @Environment(\.scenePhase) private var phase
    private var active: Bool { api.accessAllowed && phase != .background }
    var body: some View {
        Form {
            Section {
                NavigationLink { VnStatView(api: api) } label: {
                    Label("Server traffic · vnStat", systemImage: "chart.bar.xaxis")
                }
            }
            Section("Existing users") {
                if busy && directory == nil { ProgressView("Loading users…") }
                if let directory {
                    if directory.contacts.isEmpty { Text("No saved Internet users.").foregroundStyle(.secondary) }
                    ForEach(directory.contacts) { contact in
                        NavigationLink { InternetTrackerView(api: api, phone: contact.phone) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(contact.title).font(.headline); Spacer(); Text(contact.allowed ? "Allowed" : "Checks disabled").font(.caption).foregroundStyle(.secondary) }
                                if contact.title != contact.phone { Text(contact.phone).font(.subheadline) }
                                ForEach(Array(contact.lines.enumerated()), id: \.offset) { _, line in
                                    Text("\(line.number) · \(InternetTrackerFormat.provider(line.provider))").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.orange); Button("Retry") { Task { await load() } } }
            }
            Section("Open another contact") {
                OrbitPhoneNumberField(prompt: "Contact number", text: $phone, canPick: api.accessAllowed)
                if let normalized = InternetTrackerFormat.phone(phone) {
                    NavigationLink("Internet Tracker") { InternetTrackerView(api: api, phone: normalized) }
                } else {
                    Text("Choose a contact or enter their number.").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!api.accessAllowed)
        .navigationTitle("WiFi").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(api.latestReportsContext)|\(active)") {
            generation = UUID(); directory = nil; error = nil; busy = false
            if active { await load() }
        }
        .refreshable { await load() }
    }
    private func load() async {
        guard active, !busy else { return }; let epoch = generation, context = api.latestReportsContext; busy = true
        defer { if epoch == generation { busy = false } }
        do {
            let value = try await api.internetContacts()
            guard epoch == generation, active, context == api.latestReportsContext, !Task.isCancelled else { return }
            directory = value; error = nil
        } catch {
            guard epoch == generation, active, context == api.latestReportsContext, !Task.isCancelled else { return }
            self.error = "Internet users could not be loaded. Try again."
        }
    }
}
