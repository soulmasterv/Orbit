import SwiftUI

enum StudentBotMode: String, CaseIterable, Codable, Identifiable {
    case assistant, calendar, local

    var id: Self { self }
    var icon: String {
        switch self {
        case .assistant: "graduationcap"
        case .calendar: "calendar"
        case .local: "cpu"
        }
    }
    var title: String {
        switch self {
        case .assistant: "School Assistant"
        case .calendar: "Calendar"
        case .local: "Local AI"
        }
    }
}

struct StudentBotConfig: Decodable {
    let mode: StudentBotMode
    let available_modes: [String]
    let calendar_parser: DisplayValue?
    let booking_status: DisplayValue?
    let reminder_preset: DisplayValue?
    let local_model: DisplayValue?
    let classera_feed: DisplayValue?
    let auto_booking: DisplayValue?
    let stats: [String: Int?]?

    struct DisplayValue: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) {
                text = string
            } else if let enabled = try? value.decode(Bool.self) {
                text = enabled ? "Enabled" : "Disabled"
            } else {
                throw DecodingError.typeMismatch(Self.self, .init(
                    codingPath: decoder.codingPath, debugDescription: "Expected a status or label"))
            }
        }
    }

    func allows(_ candidate: StudentBotMode) -> Bool {
        available_modes.contains(candidate.rawValue)
    }
}

extension ServerAPI {
    func studentBotConfig(connection: StudentsConnection, phone: String) async throws -> StudentBotConfig {
        let data = try await mobileData(connection: connection, path: Self.botConfigPath(phone))
        return try JSONDecoder().decode(StudentBotConfig.self, from: data)
    }

    func saveStudentBotMode(connection: StudentsConnection, phone: String, mode: StudentBotMode) async throws {
        _ = try await mobileData(connection: connection, path: Self.botConfigPath(phone),
                                 method: "PUT", body: JSONEncoder().encode(["mode": mode.rawValue]))
    }

    private static func botConfigPath(_ phone: String) throws -> String {
        guard MobileRules.validPhone(phone) else { throw APIError.message("Invalid student phone number.") }
        return "/api/students/\(phone)/bot-config"
    }
}

struct StudentBotConfigView: View {
    @ObservedObject var api: ServerAPI
    let phone: String
    @State private var config: StudentBotConfig?
    @State private var selection: StudentBotMode?
    @State private var busy = false
    @State private var needsRefresh = false
    @State private var error: String?
    @State private var generation = UUID()

    var body: some View {
        Form {
            if api.accessAllowed {
                if let error { Text(error).foregroundStyle(.orange) }
                if busy { ProgressView("Checking bot configuration…") }
                if let config {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(config.mode.title).font(.headline)
                                Text("Current mode").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: config.mode.icon).foregroundStyle(StudentPalette.accent)
                        }
                        .padding(.vertical, 6)
                    }
                    Section("Choose a mode") {
                        ForEach(StudentBotMode.allCases) { mode in
                            Button {
                                selection = mode
                            } label: {
                                HStack {
                                    Label(mode.title, systemImage: mode.icon)
                                    Spacer()
                                    if !config.allows(mode) {
                                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection == mode ? StudentPalette.accent : Color.secondary)
                                        .accessibilityHidden(true)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == mode ? .isSelected : [])
                            .disabled(busy || needsRefresh || !config.allows(mode))
                        }
                        Button("Save") {
                            guard let selection else { return }
                            Task { await update(to: selection) }
                        }
                        .disabled(busy || needsRefresh || selection == config.mode
                                  || !(selection.map(config.allows) ?? false))
                    }
                    Section("Calendar and booking") {
                        LabeledContent("Calendar parser", value: config.calendar_parser?.text ?? "Unavailable")
                        LabeledContent("Booking status", value: config.booking_status?.text ?? "Unavailable")
                        LabeledContent("Reminder preset", value: config.reminder_preset?.text ?? "Unavailable")
                        LabeledContent("Classera feed", value: config.classera_feed?.text ?? "Unavailable")
                        LabeledContent("Auto-booking", value: config.auto_booking?.text ?? "Unavailable")
                    }
                    Section("Local AI") {
                        LabeledContent("Model", value: config.local_model?.text ?? "Unavailable")
                    }
                    Section("Student stats") {
                        if let stats = config.stats, !stats.isEmpty {
                            ForEach(stats.keys.sorted(), id: \.self) { key in
                                LabeledContent(key.replacingOccurrences(of: "_", with: " ").capitalized,
                                               value: (stats[key] ?? nil).map { String($0) } ?? "Unavailable")
                            }
                        } else {
                            Text("Stats unavailable").foregroundStyle(.secondary)
                        }
                    }
                }
                if error != nil && !busy {
                    Button("Refresh from server") { Task { await update() } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .modifier(StudentAppearance())
        .navigationTitle("Bot Config")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: api.accessAllowed) { if api.accessAllowed { await update() } }
        .refreshable { await update() }
        .onChange(of: api.accessAllowed) { _, allowed in
            if !allowed {
                generation = UUID()
                config = nil
                selection = nil
                error = nil
                busy = false
                needsRefresh = false
            }
        }
    }

    private func update(to mode: StudentBotMode? = nil) async {
        guard !busy, api.accessAllowed else { return }
        if let mode, needsRefresh || config?.allows(mode) != true || config?.mode == mode { return }
        let currentGeneration = generation
        busy = true
        error = nil
        defer { if generation == currentGeneration { busy = false } }

        do {
            guard let connection = try KeychainManager.loadStudentsConnection() else {
                throw APIError.message("Set up the Students connection in Settings.")
            }
            if let mode {
                needsRefresh = true
                try await api.saveStudentBotMode(connection: connection, phone: phone, mode: mode)
            }
            let updated = try await api.studentBotConfig(connection: connection, phone: phone)
            guard generation == currentGeneration, api.accessAllowed, !Task.isCancelled else { return }
            config = updated
            selection = updated.mode
            needsRefresh = false
            if let mode, updated.mode != mode { error = "The server kept the previous mode." }
        } catch {
            guard generation == currentGeneration, api.accessAllowed, !Task.isCancelled else { return }
            selection = config?.mode
            self.error = mode == nil ? "Bot configuration could not be loaded. Refresh to try again."
                : "The saved mode could not be confirmed. Refresh before trying again."
        }
    }
}
