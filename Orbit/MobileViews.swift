import SwiftUI

struct MobileHubView: View {
    @ObservedObject var api: ServerAPI
    @EnvironmentObject private var mobile: MobileStore
    var body: some View {
        List {
            Section("Student tools") {
                NavigationLink { MobileFeedbackView(api: api, selectedID: nil) } label: {
                    Label("Feedback", systemImage: "bubble.left.and.text.bubble.right")
                }
                NavigationLink { MobileEventsView(api: api) } label: {
                    Label("Recent events", systemImage: "clock")
                }
                if mobile.state?.outbox != nil {
                    NavigationLink { MessageOutboxView() } label: { Label("Saved message", systemImage: "tray") }
                }
                NavigationLink { StudentsSettingsView(api: api) } label: { Label("Connection settings", systemImage: "gearshape") }
            }
            MobileResultSection()
        }.navigationTitle("Student Tools")
        .task { await mobile.refresh() }
    }
}

struct MobileResultSection: View {
    @EnvironmentObject private var mobile: MobileStore
    var body: some View {
        Section {
            if let error = mobile.error { Text(error).foregroundStyle(.orange) }
            if let notice = mobile.notice { Text(notice).foregroundStyle(.secondary) }
        }
    }
}

struct MobileEventsView: View {
    @ObservedObject var api: ServerAPI
    @EnvironmentObject private var mobile: MobileStore
    var body: some View {
        List {
            if mobile.events.isEmpty { Text("No recent events, or the mobile API is not deployed yet.").foregroundStyle(.secondary) }
            ForEach(mobile.events) { event in
                NavigationLink { MobileEventView(api: api, eventID: event.id) } label: {
                    VStack(alignment: .leading) {
                        Text(event.title)
                        Text(Date(timeIntervalSince1970: TimeInterval(event.created_at)), style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            MobileResultSection()
        }.navigationTitle("School Events")
        .task { await mobile.refresh() }
        .refreshable { await mobile.refresh() }
    }
}

struct MobileEventView: View {
    @ObservedObject var api: ServerAPI
    let eventID: UUID
    @EnvironmentObject private var mobile: MobileStore
    @State private var event: MobileEvent?
    @State private var failure: String?
    var body: some View {
        Group {
            if let event {
                if event.kind == "answer_flagged", let id = event.feedback_id {
                    MobileFeedbackView(api: api, selectedID: id)
                } else if event.kind == "onboarding_completed" {
                    EventStudentView(api: api, phone: event.phone)
                } else { ContentUnavailableView("Event unavailable", systemImage: "bell.slash") }
            } else if let failure {
                VStack(spacing: 16) { Text(failure); Button("Try safe lookup again") { Task { await resolve() } } }.padding()
            } else { ProgressView("Opening event…") }
        }.task { await resolve() }
    }
    private func resolve() async {
        guard api.accessAllowed else { return }
        do {
            await mobile.refresh()
            let value = try await mobile.event(eventID)
            guard api.accessAllowed else { return }
            event = value; failure = nil
        } catch {
            guard api.accessAllowed else { return }
            failure = MobileRules.error(error)
        }
    }
}

private struct EventStudentView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var store: StudentsStore
    let phone: String
    init(api: ServerAPI, phone: String) {
        self.api = api; self.phone = phone
        _store = StateObject(wrappedValue: StudentsStore(api: api))
    }
    var body: some View { StudentDetailView(api: api, store: store, phone: phone) }
}

struct StudentMessageComposer: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var students: StudentsStore
    let phone: String
    @EnvironmentObject private var mobile: MobileStore
    @Environment(\.scenePhase) private var phase
    @State private var text = ""
    @State private var confirming = false
    @State private var refreshOwner = UUID()
    private var eligible: Bool {
        guard !students.requiresVerification, !students.mutationBusy, let snapshot = students.snapshot,
              let student = snapshot.students.first(where: { $0.phone == phone }) else { return false }
        return MobileRules.canSend(student, snapshot: snapshot)
    }
    var body: some View {
        Form {
            Section("One student only") {
                LabeledContent("Recipient", value: phone)
                Text("Manual plain text only. The server makes the final window and restriction check. No template fallback or automatic reminder.").font(.caption)
                if let snapshot = students.snapshot, let student = snapshot.students.first(where: { $0.phone == phone }) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Window remaining: \(snapshot.countdown(for: student)) (advisory)").font(.caption).monospacedDigit()
                    }
                }
                TextEditor(text: $text).frame(minHeight: 150).disabled(mobile.busy)
                Text("\(text.trimmingCharacters(in: .whitespacesAndNewlines).count) / 3500 characters").font(.caption)
                if !eligible { Text("Refresh required: student must be active, Allowed and inside the open 24-hour window.").foregroundStyle(.orange) }
                Button("Review message") { confirming = true }
                    .disabled(!eligible || (try? MobileRules.text(text)) == nil || mobile.busy || mobile.state?.outbox != nil || mobile.capabilities?.supportsMessages != true)
                Button("Refresh eligibility") { Task { await students.refresh(); await mobile.refresh() } }.disabled(mobile.busy)
                Text("Pricing is unknown until Meta reports it. An open window does not guarantee no charge.").font(.caption).foregroundStyle(.secondary)
            }
            if mobile.state?.outbox != nil { Section { NavigationLink("Saved operation — inspect status") { MessageOutboxView() } } }
            MobileResultSection()
        }.navigationTitle("Compose Message")
        .onAppear { students.claimVisibility(refreshOwner); text = mobile.draft(phone: phone) }
        .onDisappear { students.suspend(owner: refreshOwner) }
        .onChange(of: text) { _, value in mobile.saveDraft(phone: phone, text: value) }
        .task(id: phase == .active && api.accessAllowed) {
            if phase == .active && api.accessAllowed { await students.refresh(); await mobile.refresh() }
        }
        .task(id: "\(phase == .active)-\(mobile.state?.outbox?.requestID.uuidString ?? "none")") {
            if phase == .active && mobile.state?.outbox != nil { await mobile.boundedRecovery() }
        }
        .confirmationDialog("Send to this one student?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Confirm and authorize send", role: .destructive) { Task { await mobile.send(phone: phone, text: text) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Recipient: \(phone)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }
}

struct MessageOutboxView: View {
    @EnvironmentObject private var mobile: MobileStore
    @Environment(\.scenePhase) private var phase
    @State private var review = false
    var body: some View {
        Form {
            if let operation = mobile.state?.outbox {
                Section("Saved operation") {
                    LabeledContent("Request ID", value: operation.requestID.uuidString).font(.caption).textSelection(.enabled)
                    LabeledContent("Recipient", value: operation.phone)
                    Text(operation.text).textSelection(.enabled)
                    Text(operation.result?.explanation ?? "Outcome unconfirmed. Do not resend. Inspect the saved operation and check WhatsApp.")
                    Text(operation.result?.pricing?.summary ?? "Pricing unknown").font(.caption)
                    Button("Check status (does not send)") { Task { await mobile.recover() } }.disabled(mobile.busy)
                    Button("I reviewed this operation; start a new action") { review = true }.disabled(mobile.busy)
                }
            } else { Text("No saved message operation.") }
            MobileResultSection()
        }.navigationTitle("Message Status")
        .task(id: phase == .active) { if phase == .active { await mobile.boundedRecovery() } }
        .confirmationDialog("Review completed?", isPresented: $review, titleVisibility: .visible) {
            Button("Keep draft and start a new intentional action", role: .destructive) { mobile.reviewAndStartNew() }
            Button("Keep saved operation", role: .cancel) {}
        } message: { Text("Check WhatsApp first if the result is pending or unknown, or could not be found. A new action can duplicate a message already sent. This button does not send or retry anything.") }
    }
}

struct MobileFeedbackView: View {
    @ObservedObject var api: ServerAPI
    let selectedID: Int?
    @EnvironmentObject private var mobile: MobileStore
    @State private var reports: [FeedbackRecord] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var mutation = false
    @State private var confirming: FeedbackRecord?
    @State private var uncertain = false
    @State private var generation = 0
    var body: some View {
        List {
            if loading { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if !loading && reports.isEmpty { Text(selectedID == nil ? "No feedback available." : "Report unavailable or expired.") }
            ForEach(reports) { record in
                if selectedID != nil { reportDetails(record) }
                else {
                    NavigationLink { MobileFeedbackView(api: api, selectedID: record.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.note.isEmpty ? "Feedback #\(record.id)" : record.note).lineLimit(2)
                            Text(record.date, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                            Text(record.isResolved ? "Resolved" : "Open").font(.caption)
                        }
                    }
                }
            }
            Button("Refresh feedback") { Task { await refresh() } }.disabled(mutation)
        }.navigationTitle(selectedID == nil ? "Feedback" : "Feedback Details")
        .task { await refresh() }.refreshable { if !mutation { await refresh() } }
        .confirmationDialog(confirming?.isResolved == true ? "Reopen this report?" : "Mark report resolved?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { report in
            Button("Confirm and authorize") { Task { await resolve(report) } }
            Button("Cancel", role: .cancel) {}
        }
    }
    @ViewBuilder private func reportDetails(_ record: FeedbackRecord) -> some View {
        Section("Feedback #\(record.id)") {
            LabeledContent("Student", value: record.phone)
            LabeledContent("Reported", value: record.date.formatted(date: .abbreviated, time: .shortened))
            Text(record.note.isEmpty ? "No note provided" : record.note)
            VStack(alignment: .leading) { Text("Question").font(.caption).foregroundStyle(.secondary); Text(record.question.isEmpty ? "Unavailable" : record.question) }
            VStack(alignment: .leading) { Text("Answer").font(.caption).foregroundStyle(.secondary); Text(record.answer.isEmpty ? "Unavailable" : record.answer) }
            Text(record.isResolved ? "Resolved" : "Open")
            Button(record.isResolved ? "Reopen report" : "Mark resolved") { confirming = record }.disabled(mutation || uncertain)
        }
    }
    private func refresh() async {
        guard api.accessAllowed && !loading else { return }
        generation += 1; let epoch = generation
        loading = true; defer { if epoch == generation { loading = false } }
        do {
            guard let connection = try KeychainManager.loadStudentsConnection() else { throw APIError.message("Configure Students connection first.") }
            await mobile.refresh()
            guard mobile.capabilities?.version == 1 else { throw APIError.message("Mobile API version 1 is not confirmed.") }
            // There is no GET-by-ID endpoint. Include resolved reports on event lookup.
            let rows = try await api.fetchFeedback(connection: connection)
            guard api.accessAllowed && epoch == generation else { return }
            reports = rows.filter { selectedID == nil || $0.id == selectedID }; failure = nil; uncertain = false
        } catch { if api.accessAllowed && epoch == generation { failure = MobileRules.error(error) } }
    }
    private func resolve(_ report: FeedbackRecord) async {
        guard !mutation && !uncertain && api.accessAllowed else { return }
        generation += 1; loading = false
        mutation = true; defer { mutation = false }
        do {
            guard let connection = try KeychainManager.loadStudentsConnection() else { throw CancellationError() }
            uncertain = true
            try await api.resolveFeedback(connection: connection, id: report.id, resolved: !report.isResolved)
            await refresh()
        } catch { if api.accessAllowed { failure = MobileRules.error(error) + " Refresh before another action. No mutation was retried." } }
    }
}



