import SwiftUI

enum JarvisFunMode: String, CaseIterable, Identifiable, Encodable {
    case silly, bibo, diaa
    case diaaNoqta = "diaa-noqta"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .silly: "Hossam"
        case .bibo: "Bibo"
        case .diaa: "Diaa (both clips)"
        case .diaaNoqta: "Diaa Noqta"
        }
    }
}

struct JarvisFunCallRequest: Encodable {
    let operation = "fun_call"
    let request_id: String
    let mode: JarvisFunMode
    let destination: String?
    let message: String?

    init(mode: JarvisFunMode, number: String?, message: String, requestID: UUID = UUID()) throws {
        self.mode = mode
        request_id = requestID.uuidString.lowercased()
        if let number {
            var compact = OrbitPhoneNumberField.removingFormatting(number)
            if compact.hasPrefix("00") { compact = "+" + String(compact.dropFirst(2)) }
            if compact.hasPrefix("01"), compact.count == 11 {
                compact = "+20" + compact.dropFirst()
            } else if !compact.hasPrefix("+") {
                compact = "+" + compact
            }
            guard let normalized = DiaaCallNumber.normalized(compact) else {
                throw APIError.message("Enter a valid Egyptian mobile or international number.")
            }
            destination = normalized
        } else { destination = nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode != .bibo || trimmed.utf16.count <= 1000 else {
            throw APIError.message("Keep the Bibo message within 1,000 characters.")
        }
        self.message = mode == .bibo && !trimmed.isEmpty ? trimmed : nil
    }
}

@MainActor
final class JarvisFunCallSubmission: ObservableObject {
    @Published private(set) var requestID: String?
    @Published private(set) var result: String?
    @Published private(set) var uncertain = false
    var busy: Bool { requestID != nil }

    func acknowledgeTasksChecked() {
        guard !busy else { return }
        uncertain = false
        result = nil
    }

    func submit(_ request: JarvisFunCallRequest,
                authorize: () async throws -> Void,
                send: (JarvisFunCallRequest) async throws -> Bool) async {
        guard !busy, !uncertain else { return }
        requestID = request.request_id
        result = nil
        defer { requestID = nil }
        do { try await authorize() }
        catch {
            result = "Call was not submitted. " + error.localizedDescription
            return
        }
        do {
            let queued = try await send(request)
            if queued { result = "Call queued." }
            else { markUncertain() }
        } catch { markUncertain() }
    }

    private func markUncertain() {
        uncertain = true
        result = "Call unconfirmed. Check Tasks before placing another call. Duplicate protection lasts 15 minutes and resets if the server restarts."
    }
}

struct JarvisFunCallsView: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var session: JarvisSession
    @ObservedObject var submission: JarvisFunCallSubmission
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var mode: JarvisFunMode = .silly
    @State private var specificNumber = false
    @State private var number = ""
    @State private var message = ""
    @State private var error: String?

    private var active: Bool { api.accessAllowed && session.signedIn && phase == .active }
    private var request: JarvisFunCallRequest? {
        try? JarvisFunCallRequest(mode: mode, number: specificNumber ? number : nil, message: message)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    ForEach(JarvisFunMode.allCases) { value in
                        Button { mode = value } label: {
                            HStack {
                                Text(value.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: mode == value ? "checkmark.circle.fill" : "circle")
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.disabled(submission.busy)
                Section("Call") {
                    Picker("Target", selection: $specificNumber) {
                        Text("Me").tag(false)
                        Text("Specific number").tag(true)
                    }.pickerStyle(.segmented)
                    if specificNumber {
                        OrbitPhoneNumberField(prompt: "Phone number", text: $number,
                                              canPick: active && !submission.busy,
                                              formatSelection: { $0 })
                    }
                    if mode == .bibo {
                        TextField("Message (optional)", text: $message, axis: .vertical).lineLimit(2...5)
                        Text("Leave empty for the feeding reminder.").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(submission.busy)
                Section {
                    Button("Call with Face ID", systemImage: "phone.fill") { submit() }
                        .disabled(!active || !api.canControl || submission.busy || submission.uncertain || request == nil)
                    if submission.busy { ProgressView("Submitting call…") }
                    if let result = submission.result { Text(result).foregroundStyle(submission.uncertain ? Color.orange : Color.secondary) }
                    if submission.uncertain {
                        Button("I've checked Tasks") { submission.acknowledgeTasksChecked() }.disabled(submission.busy)
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Fun calls")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(submission.busy) } }
            .interactiveDismissDisabled(submission.busy)
            .onChange(of: api.accessAllowed) { _, allowed in if !allowed { dismiss() } }
            .onChange(of: phase) { _, next in if next == .background { number = ""; message = ""; dismiss() } }
        }
    }

    private func submit() {
        guard active, api.canControl, !submission.busy, !submission.uncertain else { return }
        do {
            let request = try JarvisFunCallRequest(mode: mode, number: specificNumber ? number : nil, message: message)
            let context = api.latestReportsContext
            error = nil
            Task {
                await submission.submit(request, authorize: {
                    try await DeviceAuthorization.authorizeFaceID(reason: "Authorize this Fun call")
                    try await DeviceAuthorization.waitForCallForeground(
                        isForeground: { UIApplication.shared.applicationState == .active },
                        mayContinue: { api.accessAllowed && api.canControl && api.latestReportsContext == context && session.signedIn })
                }, send: { request in
                    guard api.accessAllowed, api.canControl, api.latestReportsContext == context else { throw CancellationError() }
                    return try await session.funCallRequest(request)
                })
            }
        } catch { self.error = error.localizedDescription }
    }
}
