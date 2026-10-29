import SwiftUI
import Security

struct ClasseraTextPending: Codable {
    let endpoint: String
    let phone: String
    let id: String
}
enum ClasseraTextVault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Orbit",
         kSecAttrAccount as String: "classera-text-operation.v1"]
    }
    static func load() throws -> ClasseraTextPending? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw APIError.message("Unlock iPhone to review the saved message request.") }
        return try JSONDecoder().decode(ClasseraTextPending.self, from: data)
    }
    static func save(_ value: ClasseraTextPending?) throws {
        if let value {
            let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil) }
            guard status == errSecSuccess else { throw APIError.message("Could not save the request identity. Nothing was submitted.") }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.message("Could not clear the saved message request.") }
        }
    }
}

struct ClasseraPlainTextView: View {
    @ObservedObject var api: ServerAPI
    let phone: String
    @Environment(\.scenePhase) private var phase
    @State private var response: ClasseraMessagingResponse?
    @State private var received = ContinuousClock.now
    @State private var klass = ""
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    @State private var vaultReady = false
    @State private var pending: ClasseraTextPending?
    @State private var operation: ClasseraTextOperation?
    @State private var generation = 0
    private var window: ClasseraWhatsAppWindow? { response?.whatsappWindows.first { $0.className == klass } }
    private var validText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 4096 }
    private var canSend: Bool {
        vaultReady && pending == nil && !busy && api.accessAllowed && phase == .active && validText &&
        window?.canSendPlaintext == true && (window?.remainingSeconds(since: received) ?? 0) >= 30
    }
    var body: some View {
        Form {
            Section("One recipient only") {
                Text(phone).monospacedDigit().textSelection(.enabled)
                Picker("Classera", selection: $klass) {
                    Text("Choose class").tag("")
                    ForEach(response?.whatsappWindows ?? []) { item in
                        Text(ClasseraClass.title(item.className)).tag(item.className)
                    }
                }.disabled(busy || pending != nil)
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(window?.displayLabel(since: received) ?? "Window unavailable").font(.subheadline)
                }
                Button("Refresh window") { Task { await refresh() } }.disabled(busy)
            }
            if let pending {
                Section("Saved message request") {
                    Text("Recipient: " + pending.phone)
                    Text("Request: " + pending.id).font(.caption).textSelection(.enabled)
                    Text(operation.map { statusText($0.status) } ?? "Outcome unconfirmed. Do not send again; check status first.")
                    Button("Check status — does not send") { Task { await checkStatus() } }.disabled(busy)
                    if let operation, ["accepted", "sent", "delivered", "read", "failed"].contains(operation.status) {
                        Button("Reviewed — compose a new message") {
                            do { try ClasseraTextVault.save(nil); self.pending = nil; self.operation = nil; text = "" }
                            catch { self.error = error.localizedDescription }
                        }.disabled(busy)
                    }
                }
            } else {
                Section("Plain-text message") {
                    TextEditor(text: $text).frame(minHeight: 140).disabled(busy)
                    Text("\(text.count) / 4096 characters").font(.caption).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Button("Review and send to ONE person") { confirm = true }.disabled(!canSend)
                    }
                    Text("The server checks the real WhatsApp window again before sending. This never extends it or sends an approved template.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if busy { ProgressView("Please wait…") }
            if let error { Text(error).foregroundStyle(.orange) }
        }.scrollContentBackground(.hidden).modifier(StudentAppearance())
        .navigationTitle("Plain-text message").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .task(id: phase == .active && api.accessAllowed) {
            guard phase == .active && api.accessAllowed else {
                if phase == .background || !api.accessAllowed { generation += 1; busy = false; text = ""; response = nil; operation = nil; confirm = false }
                return
            }
            do { pending = try ClasseraTextVault.load(); vaultReady = true }
            catch { vaultReady = false; self.error = error.localizedDescription }
            await refresh()
        }
        .task(id: "\(phase == .active && api.accessAllowed)-\(pending?.id ?? "none")") {
            guard phase == .active && api.accessAllowed && pending != nil else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard phase == .active && api.accessAllowed && pending != nil else { return }
                if !busy { await checkStatus() }
                if let state = operation?.status, ["read", "failed"].contains(state) { return }
            }
        }
        .onDisappear { generation += 1; text = ""; response = nil }
        .confirmationDialog("Send this message to ONE person?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Send message") { Task { await send() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("\(phone) · \(ClasseraClass.title(klass))\n\n\(text)") }
    }
    private func statusText(_ status: String) -> String {
        switch status {
        case "accepted": return "Accepted by WhatsApp. Delivery is not yet confirmed."
        case "sent": return "WhatsApp confirms the message was sent."
        case "delivered": return "Delivery confirmed by the WhatsApp webhook."
        case "read": return "Read confirmed by the WhatsApp webhook."
        case "failed": return "WhatsApp reported a failure. No automatic retry."
        default: return "Outcome uncertain. Do not resend; check this request's status."
        }
    }
    private func refresh() async {
        guard !busy && api.accessAllowed && phase == .active else { return }
        generation += 1; let epoch = generation; busy = true
        defer { if generation == epoch { busy = false } }
        do {
            let value = try await api.loadClasseraMessaging(phone: phone)
            guard generation == epoch && api.accessAllowed && phase == .active else { return }
            response = value; received = .now; error = nil
            if klass.isEmpty { klass = value.whatsappWindows.first?.className ?? "" }
        } catch { if generation == epoch { self.error = error.localizedDescription } }
    }
    private func send() async {
        guard canSend else { return }
        let payload = ClasseraTextPayload(requestID: UUID().uuidString.lowercased(), className: klass, text: text)
        let saved = ClasseraTextPending(endpoint: api.baseURL, phone: phone, id: payload.requestID)
        generation += 1; let epoch = generation; busy = true
        defer { if generation == epoch { busy = false } }
        do {
            let result = try await api.sendClasseraText(phone: phone, payload: payload) {
                if let _ = try ClasseraTextVault.load() { throw APIError.message("Review the existing saved request first.") }
                try ClasseraTextVault.save(saved); pending = saved
            }
            guard generation == epoch && api.accessAllowed else { return }
            operation = result; error = nil; text = ""
        } catch {
            guard generation == epoch else { return }
            if let rejected = error as? ClasseraTextRejection {
                if (try? ClasseraTextVault.load())?.id == saved.id {
                    do { try ClasseraTextVault.save(nil); pending = nil } catch { }
                }
                response = nil; self.error = rejected.localizedDescription
            } else {
                self.error = pending == nil ? "No message was submitted." : "The outcome may be uncertain. Check the saved request status; do not send again."
            }
        }
    }
    private func checkStatus() async {
        guard !busy, let pending, pending.endpoint == api.baseURL else {
            error = "Use the original Orbit connection to check this saved request."; return
        }
        generation += 1; let epoch = generation; busy = true
        defer { if generation == epoch { busy = false } }
        do {
            let result = try await api.classeraTextStatus(phone: pending.phone, id: pending.id)
            guard epoch == generation && api.accessAllowed else { return }
            operation = result; error = nil
        } catch { if epoch == generation { self.error = "Status could not be confirmed. No message was retried." } }
    }
}

