import SwiftUI
import Security

struct ClasseraReportSettings: Codable, ClasseraVersioned {
    struct Capabilities: Codable { let bulk_ai: Bool; let next_notice: Bool }
    struct Counts: Codable {
        let eligible: Int; let ai: Int; let no_ai: Int; let preserved: Int
        var isValid: Bool { [eligible, ai, no_ai, preserved].allSatisfy { $0 >= 0 } && ai + no_ai == eligible }
    }
    struct Notice: Codable {
        let id: String; let text: String; let state: String; let batch_id: String?; let created_at: String
        let outcomes: [String: Int]?
    }
    let version: Int; let class_id: String; let class_name: String; let revision: String
    let capabilities: Capabilities; let notice_unavailable_reason: String?
    let queued_notice: Notice?; let latest_notice: Notice?; let counts: Counts
    var isValid: Bool {
        version == 1 && ["classera-1": "12F", "classera-2": "12E"][class_id] == class_name &&
        revision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil && counts.isValid &&
        (queued_notice == nil || queued_notice?.state == "queued")
    }
}

struct ClasseraAIPreview: Decodable, ClasseraVersioned {
    let version: Int; let class_id: String; let revision: String; let ai_enabled: Int
    let affected_count: Int; let counts: ClasseraReportSettings.Counts
    var isValid: Bool {
        version == 1 && ["classera-1", "classera-2"].contains(class_id) && [0, 1].contains(ai_enabled) &&
        revision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil && counts.isValid &&
        affected_count == (ai_enabled == 1 ? counts.no_ai : counts.ai)
    }
}
struct ClasseraBulkAIPayload: Encodable {
    let request_id: String; let expected_revision: String; let ai_enabled: Int; let expected_affected_count: Int
    init(_ preview: ClasseraAIPreview) {
        request_id = UUID().uuidString.lowercased(); expected_revision = preview.revision
        ai_enabled = preview.ai_enabled; expected_affected_count = preview.affected_count
    }
}
struct ClasseraNoticePayload: Encodable {
    let request_id: String; let expected_revision: String; let text: String
}
struct ClasseraReportOperation: Decodable, ClasseraVersioned {
    let version: Int; let request_id: String; let class_id: String; let kind: String
    let status: String; let affected_count: Int; let settings: ClasseraReportSettings
    var isValid: Bool {
        version == 1 && UUID(uuidString: request_id)?.uuidString.lowercased() == request_id &&
        ["completed", "cancelled"].contains(status) && ["bulk-ai", "next-notice", "cancelled"].contains(kind) &&
        affected_count >= 0 && settings.isValid && settings.class_id == class_id
    }
}
struct ClasseraReportPending: Codable {
    let endpoint: String; let class_id: String; let request_id: String; let kind: String
}
enum ClasseraReportVault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Orbit",
         kSecAttrAccount as String: "report-administration-operation.v1"]
    }
    static func load() throws -> ClasseraReportPending? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw APIError.message("Unlock iPhone to check the saved report action.") }
        return try JSONDecoder().decode(ClasseraReportPending.self, from: data)
    }
    static func save(_ pending: ClasseraReportPending?) throws {
        guard let pending else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.message("Could not clear the saved report action.") }
            return
        }
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(pending),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw APIError.message("Could not save the request identity. Nothing was submitted.") }
    }
}

@MainActor
final class ClasseraReportSettingsStore: ObservableObject {
    @Published private(set) var settings: ClasseraReportSettings?
    @Published private(set) var preview: ClasseraAIPreview?
    @Published private(set) var pending: ClasseraReportPending?
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var vaultReady = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var draft = ""
    private var drafts: [String: String] = [:]
    private var classID = ""
    private var endpoint = ""
    private var generation = 0
    private let loadPending: () throws -> ClasseraReportPending?
    private let savePending: (ClasseraReportPending?) throws -> Void
    init(loadPending: @escaping () throws -> ClasseraReportPending? = ClasseraReportVault.load,
         savePending: @escaping (ClasseraReportPending?) throws -> Void = ClasseraReportVault.save) {
        self.loadPending = loadPending; self.savePending = savePending
    }
    var canMutate: Bool { vaultReady && pending == nil && !busy && !loading && settings != nil }
    func setDraft(_ text: String) { draft = text; drafts[classID] = text }
    func clear() {
        generation += 1; settings = nil; preview = nil; loading = false; vaultReady = false
        drafts.removeAll(); draft = ""; error = nil; notice = nil
    }
    func refresh(api: ServerAPI, classID: String) async {
        guard api.accessAllowed && !busy && !Task.isCancelled else { return }
        generation += 1; let epoch = generation
        if self.classID != classID || endpoint != api.baseURL {
            if endpoint != api.baseURL { drafts.removeAll() }
            settings = nil; preview = nil; error = nil; notice = nil
        }
        self.classID = classID; endpoint = api.baseURL; loading = true
        vaultReady = false; preview = nil
        defer { if generation == epoch { loading = false } }
        do {
            pending = try loadPending(); vaultReady = true
            let value = try await api.classeraReportSettings(classID)
            guard generation == epoch && api.accessAllowed && !Task.isCancelled else { return }
            settings = value; draft = drafts[classID] ?? value.queued_notice?.text ?? ""; error = nil
        } catch {
            guard generation == epoch && api.accessAllowed else { return }
            self.error = Self.safe(error)
        }
    }
    func prepareAI(api: ServerAPI, value: Int) async {
        guard canMutate, settings?.capabilities.bulk_ai == true else { return }
        generation += 1; let epoch = generation; loading = true; preview = nil
        defer { if generation == epoch { loading = false } }
        do {
            let result = try await api.classeraBulkAIPreview(classID, value: value)
            guard generation == epoch && api.accessAllowed && !Task.isCancelled else { return }
            preview = result; error = nil
        } catch { if generation == epoch && api.accessAllowed { self.error = Self.safe(error) } }
    }
    func applyAI(api: ServerAPI, confirmed: ClasseraAIPreview) async {
        guard canMutate, settings?.capabilities.bulk_ai == true, let preview,
              preview.class_id == confirmed.class_id && preview.revision == confirmed.revision &&
              preview.ai_enabled == confirmed.ai_enabled && preview.affected_count == confirmed.affected_count else { return }
        let payload = ClasseraBulkAIPayload(confirmed)
        await mutate(api: api, kind: "bulk-ai", requestID: payload.request_id) { before in
            try await api.applyClasseraBulkAI(confirmed.class_id, payload: payload, beforeSubmit: before)
        }
    }
    func saveNotice(api: ServerAPI, confirmedText: String, revision: String) async {
        guard canMutate, let settings, settings.capabilities.next_notice,
              settings.revision == revision, draft == confirmedText, confirmedText.count <= 1000 else { return }
        let payload = ClasseraNoticePayload(request_id: UUID().uuidString.lowercased(), expected_revision: revision, text: confirmedText)
        await mutate(api: api, kind: "next-notice", requestID: payload.request_id) { before in
            try await api.saveClasseraReportNotice(self.classID, payload: payload, beforeSubmit: before)
        }
    }
    private func mutate(api: ServerAPI, kind: String, requestID: String,
        submit: (_ before: () throws -> Void) async throws -> ClasseraReportOperation) async {
        generation += 1; let epoch = generation; busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            let result = try await submit {
                let value = ClasseraReportPending(endpoint: api.baseURL, class_id: self.classID, request_id: requestID, kind: kind)
                try self.savePending(value); self.pending = value
            }
            guard generation == epoch && api.accessAllowed else { return }
            try await accept(api: api, result: result, epoch: epoch)
        } catch {
            guard generation == epoch && api.accessAllowed else { return }
            self.error = Self.safe(error); preview = nil
            if let failure = error as? ClasseraMonitoringFailure, case .http(let status, _) = failure,
               [400, 401, 403, 404, 409, 422].contains(status) {
                do { try savePending(nil); pending = nil } catch { vaultReady = false }
                if status == 409 {
                    if let latest = try? await api.classeraReportSettings(classID), generation == epoch && api.accessAllowed { settings = latest }
                    self.error = "Choices changed on the server. Review the latest settings and start a new preview before applying."
                }
            } else if let saved = pending, saved.endpoint == api.baseURL {
                // Exactly one GET recovery; never repeat a mutation after a timeout.
                do {
                    let result = try await api.classeraReportOperation(saved.class_id, requestID: saved.request_id)
                    guard generation == epoch && api.accessAllowed else { return }
                    try await accept(api: api, result: result, epoch: epoch)
                } catch { if generation == epoch && api.accessAllowed { self.error = "This action may have succeeded. Check its saved status before another attempt; nothing will be resent automatically." } }
            }
        }
    }
    private func accept(api: ServerAPI, result: ClasseraReportOperation, epoch: Int) async throws {
        guard let pending, result.request_id == pending.request_id && result.class_id == pending.class_id else { throw ClasseraMonitoringFailure.uncertain }
        let latest = try await api.classeraReportSettings(result.class_id)
        guard generation == epoch && api.accessAllowed && !Task.isCancelled else { throw ClasseraMonitoringFailure.uncertain }
        try savePending(nil); self.pending = nil
        if classID == result.class_id {
            settings = latest; preview = nil
            if result.kind == "next-notice" { drafts[classID] = nil; draft = latest.queued_notice?.text ?? "" }
        }
        error = nil
        notice = result.status == "cancelled" ? "The unresolved request was cancelled. A delayed copy cannot apply it." : result.kind == "bulk-ai" ? "Updated \(result.affected_count) subscriptions. No message was sent." : "Notice settings saved. This does not send a message now."
    }
    func checkPending(api: ServerAPI, cancel: Bool = false) async {
        guard !busy && api.accessAllowed, let pending else { return }
        guard pending.endpoint == api.baseURL else { error = "Restore the original Orbit server connection to review this saved action."; return }
        generation += 1; let epoch = generation; busy = true
        defer { busy = false }
        do {
            let result: ClasseraReportOperation
            if cancel { result = try await api.cancelClasseraReportOperation(pending.class_id, requestID: pending.request_id) }
            else { result = try await api.classeraReportOperation(pending.class_id, requestID: pending.request_id) }
            guard generation == epoch && api.accessAllowed else { return }
            try await accept(api: api, result: result, epoch: epoch)
        } catch { if generation == epoch && api.accessAllowed { self.error = cancel ? "Could not confirm cancellation. Check status again before another action." : "The saved action is not confirmed yet. Check again, or explicitly cancel the unresolved request." } }
    }
    static func safe(_ error: Error) -> String {
        if let failure = error as? ClasseraMonitoringFailure {
            switch failure {
            case .http(401, _), .http(403, _): return "Owner authentication failed. Check the Orbit connection in Settings."
            case .http(404, _): return "Report settings are not installed on this backend yet."
            case .http(409, _): return "Choices changed. Refresh and review before applying."
            case .http(422, _): return "The server rejected these choices. Refresh and review the input."
            case .notSent: return "No action was submitted."
            default: break
            }
        }
        return "Report settings could not be confirmed. Refresh or check the saved action; no automatic retry will change subscriptions."
    }
}

struct ClasseraReportSettingsView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var store: ClasseraReportSettingsStore
    @Environment(\.scenePhase) private var phase
    @State private var classID = "classera-1"
    @State private var aiConfirmation: ClasseraAIPreview?
    @State private var noticeConfirmation: NoticeReview?
    @State private var cancelConfirmation = false
    private struct NoticeReview: Identifiable { let id = UUID(); let text: String; let revision: String }
    init(api: ServerAPI, store: ClasseraReportSettingsStore? = nil) {
        self.api = api; _store = StateObject(wrappedValue: store ?? ClasseraReportSettingsStore())
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Selected class", selection: $classID) {
                    Text("Classera 1 (F)").tag("classera-1"); Text("Classera 2 (E)").tag("classera-2")
                }.pickerStyle(.segmented).disabled(store.busy)
                if store.loading || store.busy { ProgressView(store.busy ? "Checking action…" : "Refreshing settings…") }
                if let error = store.error { Text(error).font(.subheadline).foregroundStyle(.orange) }
                if let notice = store.notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
                if let saved = store.pending {
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Unconfirmed action · \(saved.class_id == "classera-1" ? "12F" : "12E")").font(.headline)
                            Text("This action may have succeeded. New changes stay unavailable until it is checked or explicitly cancelled.").font(.caption).foregroundStyle(.secondary)
                            Button("Check saved status") { Task { await store.checkPending(api: api) } }.disabled(store.busy)
                            Button("Cancel unresolved request", role: .destructive) { cancelConfirmation = true }.disabled(store.busy)
                        }
                    }
                }
                if let value = store.settings {
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Next report notice").font(.headline)
                            Text("For the next class-wide daily report only. Manual one-person sends do not consume it.").font(.caption).foregroundStyle(.secondary)
                            Text("Uses plain text only inside a verified 24-hour window; otherwise it requires the approved classera_wa_notice template. Unavailable notices are skipped and recorded; report delivery continues.").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: Binding(get: { store.draft }, set: store.setDraft))
                                .frame(minHeight: 110).scrollContentBackground(.hidden)
                                .disabled(!value.capabilities.next_notice || !store.canMutate)
                                .accessibilityLabel("Next report notice")
                            Text("\(store.draft.count)/1000 characters").font(.caption).foregroundStyle(.secondary)
                            if !value.capabilities.next_notice {
                                Label("Awaiting verified report-sender installation", systemImage: "lock.fill").font(.caption).foregroundStyle(.yellow)
                            }
                            if let queued = value.queued_notice { Text("Queued for the next report: \(queued.text)").font(.caption) }
                            if let latest = value.latest_notice, latest.state != "queued" {
                                Text("Last notice: \(latest.state.capitalized)").font(.caption).foregroundStyle(.secondary)
                                ForEach((latest.outcomes ?? [:]).keys.sorted(), id: \.self) { key in
                                    LabeledContent(Self.outcomeLabel(key), value: String(latest.outcomes?[key] ?? 0)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Review clearing notice" : "Review next-report notice") {
                                noticeConfirmation = NoticeReview(text: store.draft, revision: value.revision)
                            }.disabled(!store.canMutate || !value.capabilities.next_notice || store.draft.count > 1000 || store.draft == (value.queued_notice?.text ?? ""))
                        }
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Class subscription preferences").font(.headline)
                            LabeledContent("Eligible subscriptions", value: String(value.counts.eligible))
                            HStack { Text("AI: \(value.counts.ai)"); Spacer(); Text("No AI: \(value.counts.no_ai)") }.font(.subheadline)
                            Text("Disabled, suspended, blocked and unfinished signups stay unchanged. The other class is unaffected.").font(.caption).foregroundStyle(.secondary)
                            Button("Review force all AI") { Task { await store.prepareAI(api: api, value: 1) } }
                                .disabled(!store.canMutate || !value.capabilities.bulk_ai || value.counts.no_ai == 0)
                            Button("Review force all No AI") { Task { await store.prepareAI(api: api, value: 0) } }
                                .disabled(!store.canMutate || !value.capabilities.bulk_ai || value.counts.ai == 0)
                            if let preview = store.preview {
                                Divider()
                                Text("\(preview.affected_count) subscriptions will change to \(preview.ai_enabled == 1 ? "AI" : "No AI").").font(.subheadline)
                                Text("\(preview.counts.preserved) subscriptions are preserved.").font(.caption).foregroundStyle(.secondary)
                                Button("Apply to \(preview.class_id == "classera-1" ? "12F" : "12E")") { aiConfirmation = preview }
                                    .disabled(!store.canMutate || preview.affected_count == 0)
                            }
                        }
                    }
                }
                Button("Refresh settings") { Task { await store.refresh(api: api, classID: classID) } }
                    .disabled(store.busy || store.loading || !api.accessAllowed)
            }.padding(16)
        }.modifier(StudentAppearance())
        .navigationTitle("Report settings").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(store.busy)
        .task(id: "\(classID)|\(phase == .active)|\(api.accessAllowed)|\(api.baseURL)") {
            guard api.accessAllowed && phase != .background else { store.clear(); return }
            guard phase == .active else { return }
            await store.refresh(api: api, classID: classID)
        }
        .onDisappear { store.clear() }
        .onChange(of: api.accessAllowed) { _, allowed in if !allowed { aiConfirmation = nil; noticeConfirmation = nil; cancelConfirmation = false; store.clear() } }
        .onChange(of: phase) { _, value in if value == .background { aiConfirmation = nil; noticeConfirmation = nil; cancelConfirmation = false; store.clear() } }
        .refreshable { await store.refresh(api: api, classID: classID) }
        .confirmationDialog("Change selected class preferences?", isPresented: Binding(get: { aiConfirmation != nil }, set: { if !$0 { aiConfirmation = nil } }), titleVisibility: .visible, presenting: aiConfirmation) { preview in
            Button("Apply to \(preview.affected_count) subscriptions") { Task { await store.applyAI(api: api, confirmed: preview) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("This changes only eligible subscriptions in the selected class. No WhatsApp message is sent now.") }
        .confirmationDialog("Save next-report notice?", isPresented: Binding(get: { noticeConfirmation != nil }, set: { if !$0 { noticeConfirmation = nil } }), titleVisibility: .visible, presenting: noticeConfirmation) { review in
            Button(review.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Clear queued notice" : "Queue for next report") { Task { await store.saveNotice(api: api, confirmedText: review.text, revision: review.revision) } }
            Button("Cancel", role: .cancel) {}
        } message: { review in Text(review.text.isEmpty ? "Only an unclaimed queued notice is cleared. An already-started report is unchanged." : review.text + "\n\nNext class-wide report only. Closed or unknown windows need an approved notice template; otherwise the notice is skipped and recorded.") }
        .confirmationDialog("Cancel unresolved request?", isPresented: $cancelConfirmation, titleVisibility: .visible) {
            Button("Cancel unresolved request", role: .destructive) { Task { await store.checkPending(api: api, cancel: true) } }
            Button("Keep checking", role: .cancel) {}
        } message: { Text("If it already completed, its result is shown. Otherwise the server prevents a delayed copy from applying. This does not undo completed changes.") }
    }
    private static func outcomeLabel(_ key: String) -> String {
        ["accepted": "Accepted by provider", "failed": "Failed", "unknown": "Outcome unknown",
         "pending": "Waiting for report", "reserved": "Dispatch unconfirmed",
         "skipped_window_closed": "Skipped: closed window / template unavailable",
         "skipped_window_unknown": "Skipped: unknown window / template unavailable",
         "skipped_report_failed": "Skipped: report not accepted",
         "skipped_ineligible": "Skipped: student no longer eligible"][key] ?? "Unrecognized outcome"
    }
}
