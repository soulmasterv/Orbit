import SwiftUI

struct JarvisMemory: Decodable {
    struct Entry: Decodable, Identifiable {
        let id: String
        let text: String
        let type: String
        let sensitive: Bool
        let createdAt: String
        let source: String
    }
    let enabled: Bool
    let shareWithAI: Bool
    let blockedTopics: [String]
    let entries: [Entry]
}

struct JarvisMemoryResponse: Decodable {
    let memory: JarvisMemory?
}

struct JarvisMemoryView: View {
    @ObservedObject var session: JarvisSession
    @ObservedObject var api: ServerAPI
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var memory: JarvisMemory?
    @State private var search = ""
    @State private var entry = ""
    @State private var topic = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmSharing = false
    @State private var deleting: JarvisMemory.Entry?

    private var active: Bool { phase == .active && api.accessAllowed && session.signedIn }
    private var editable: Bool { active && memory != nil && !busy }
    private var entries: [JarvisMemory.Entry] {
        (memory?.entries ?? []).reversed().filter {
            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
                || $0.type.localizedCaseInsensitiveContains(search)
                || $0.source.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if busy { ProgressView("Updating memory…") }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.orange)
                        Button("Retry") { Task { await load() } }.disabled(busy || !active)
                    }
                }
                if let memory, active {
                    Section {
                        Toggle("Automatically save memories", isOn: Binding(get: { memory.enabled }, set: {
                            change($0 ? "resume" : "pause")
                        }))
                        Toggle("Share memories with AI", isOn: Binding(get: { memory.shareWithAI }, set: {
                            if $0 { confirmSharing = true } else { change("share_off") }
                        }))
                    }.disabled(!editable)
                    Section("Add memory") {
                        TextField("Write a memory", text: $entry, axis: .vertical).lineLimit(3...6)
                        Button("Add") { change("add", text: entry) }
                            .disabled(!editable || entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.count > 2000)
                    }
                    Section("Memories · \(memory.entries.count)") {
                        TextField("Search memories", text: $search)
                        if entries.isEmpty { Text(search.isEmpty ? "No saved memories." : "No matching memories.").foregroundStyle(.secondary) }
                        ForEach(entries) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.text).textSelection(.enabled)
                                Text([item.type, item.source, item.sensitive ? "Sensitive" : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let date = ISO8601DateFormatter.memory.date(from: item.createdAt) {
                                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Delete", role: .destructive) { deleting = item }.disabled(!editable)
                            }
                        }
                    }
                    Section("Blocked topics") {
                        ForEach(memory.blockedTopics, id: \.self) { value in
                            HStack {
                                Text(value)
                                Spacer()
                                Button("Unblock") { change("unblock", text: value) }.disabled(!editable)
                            }
                        }
                        TextField("Topic to block", text: $topic)
                        Button("Block topic") { change("block", text: topic) }
                            .disabled(!editable || topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Usage budgets") {
                    Text("300 text requests per rolling 24 hours · 12 per minute")
                    Text("60 voice sessions per rolling 24 hours")
                }.font(.footnote)
            }
            .navigationTitle("JARVIS Memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(!active || busy)
                }
            }
            .alert("Enable AI sharing?", isPresented: $confirmSharing) {
                Button("Enable sharing") { change("share_on") }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Relevant ordinary memories will be sent to the AI provider when answering. Sensitive entries are excluded. Automatic sensitivity detection can miss information. Review your memories before enabling sharing.")
            }
            .alert("Delete memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) { if let item = deleting { change("delete", id: item.id) }; deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            }
            .task { await load() }
            .onChange(of: active) { _, allowed in
                if !allowed { memory = nil; entry = ""; topic = ""; search = ""; confirmSharing = false; deleting = nil; dismiss() }
            }
        }
    }

    private func change(_ action: String, id: String? = nil, text: String? = nil) {
        guard editable else { return }
        Task { await load(action: action, id: id, text: text) }
    }

    @MainActor private func load(action: String? = nil, id: String? = nil, text: String? = nil) async {
        guard active, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let next = try await session.memoryRequest(action: action, id: id, text: text)
            guard active, !Task.isCancelled else { return }
            memory = next
            if action == "add" { entry = "" }
            if action == "block" { topic = "" }
        } catch {
            guard active, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            if action != nil { self.error = "The change could not be verified. Refresh memory before retrying. " + error.localizedDescription }
        }
    }
}

private extension ISO8601DateFormatter {
    static var memory: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
