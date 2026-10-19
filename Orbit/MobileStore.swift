import Foundation
import Combine

@MainActor
final class MobileStore: ObservableObject {
    @Published private(set) var capabilities: MobileCapabilities?
    @Published private(set) var events: [MobileEvent] = []
    @Published private(set) var state: MobileSecureState?
    @Published private(set) var busy = false
    @Published private(set) var pushBusy = false
    @Published private(set) var error: String?
    @Published var notice: String?
    private let api: ServerAPI
    private let load: () throws -> MobileSecureState
    private let save: (MobileSecureState) throws -> Void
    private let connection: () throws -> StudentsConnection?
    private var generation = 0
    private var foregroundBusy = false
    private var capabilityConnection: StudentsConnection?

    init(api: ServerAPI, load: @escaping () throws -> MobileSecureState = KeychainManager.loadMobileState,
         save: @escaping (MobileSecureState) throws -> Void = KeychainManager.saveMobileState,
         connection: @escaping () throws -> StudentsConnection? = KeychainManager.loadStudentsConnection) {
        self.api = api; self.load = load; self.save = save; self.connection = connection
    }

    private func ensureLoaded() throws {
        guard api.accessAllowed else { throw CancellationError() }
        if state == nil { let restored = try load(); try save(restored); state = restored }
    }
    private func update(_ change: (inout MobileSecureState) -> Void) throws {
        try ensureLoaded()
        guard var next = state else { throw CancellationError() }
        change(&next)
        try save(next) // Publish only after secure persistence succeeds.
        state = next
    }
    func suspend() {
        generation += 1; capabilities = nil; events = []
        capabilityConnection = nil
        // In-flight sends retain their durable operation; never replay on unlock.
        state = nil
    }
    private func configured() throws -> StudentsConnection {
        guard let value = try connection() else { throw APIError.message("Configure the Students HTTPS connection first.") }
        return try value.validated()
    }
    func refresh() async {
        guard api.accessAllowed && !foregroundBusy else { return }
        foregroundBusy = true
        defer { foregroundBusy = false }
        let epoch = generation
        do {
            try ensureLoaded()
            let configured = try configured()
            let data = try await api.mobileData(connection: configured, path: "/api/mobile/capabilities")
            let value = try JSONDecoder().decode(MobileCapabilities.self, from: data)
            guard api.accessAllowed && epoch == generation else { return }
            guard value.version == 1 else { throw APIError.message("Mobile API version 1 is not deployed. Existing Students controls remain available.") }
            capabilities = value; capabilityConnection = configured; error = nil
            if value.supportsEvents {
                let feed = try await api.mobileData(connection: configured, path: "/api/events?limit=50")
                let decoded = try JSONDecoder().decode([MobileEvent].self, from: feed)
                guard api.accessAllowed && epoch == generation else { return }
                var seen = Set<UUID>()
                events = decoded.filter { seen.insert($0.id).inserted }
            }
        } catch {
            guard api.accessAllowed && epoch == generation else { return }
            capabilities = nil; capabilityConnection = nil; self.error = MobileRules.error(error)
        }
    }

    func draft(phone: String) -> String { state?.drafts[phone] ?? "" }
    func saveDraft(phone: String, text: String) {
        do { try update { $0.drafts[phone] = text } } catch { self.error = MobileRules.error(error) }
    }
    func send(phone: String, text: String) async {
        guard !busy && !pushBusy && !api.actionBusy && api.accessAllowed else { return }
        busy = true
        defer { busy = false }
        do {
            try ensureLoaded()
            guard state?.outbox == nil else { throw APIError.message("Review the saved operation before starting a new message.") }
            let text = try MobileRules.text(text)
            guard MobileRules.validPhone(phone) else { throw APIError.message("Invalid student identifier.") }
            let configured = try configured()
            // Recheck support and student eligibility immediately before dispatch.
            await refresh()
            guard capabilities?.supportsMessages == true && capabilityConnection == configured else { throw APIError.message("Version 1 message/idempotency support is not confirmed.") }
            let snapshot = try await api.fetchStudents(connection: configured)
            guard let student = snapshot.students.first(where: { $0.phone == phone }), MobileRules.canSend(student, snapshot: snapshot) else {
                throw APIError.message("Sending requires active onboarding, Allowed activity and an open 24-hour window. Refresh the student.")
            }
            try await api.authorizeMobileSend()
            guard api.accessAllowed, try self.configured() == configured else { throw CancellationError() }
            var operation = PendingAdminMessage(requestID: UUID(), connection: configured, phone: phone, text: text)
            operation.attempted = true
            try update { $0.outbox = operation; $0.drafts[phone] = text }
            // This is the ONLY POST. Once persisted, every recovery path is GET.
            let body = try JSONEncoder().encode(["text": text])
            let resultData = try await api.mobileData(connection: configured, path: "/api/students/\(phone)/messages",
                method: "POST", body: body, requestID: operation.requestID)
            try record(resultData, expected: operation.requestID)
            error = nil
        } catch {
            guard api.accessAllowed else { return }
            self.error = MobileRules.error(error)
            if state?.outbox != nil { notice = "The operation is saved. Check status using GET; no message will be resent." }
        }
    }
    private func record(_ data: Data, expected: UUID) throws {
        let result = try JSONDecoder().decode(AdminMessage.self, from: data)
        guard result.request_id == expected, let operation = state?.outbox,
              result.phone == operation.phone || result.phone.isEmpty else { throw APIError.message("Message result identity did not match. Keep the saved operation for review.") }
        try update { if $0.outbox?.requestID == expected { $0.outbox?.result = result } }
    }
    func recover() async {
        guard !busy && api.accessAllowed else { return }
        busy = true
        defer { busy = false }
        do {
            try ensureLoaded()
            guard let operation = state?.outbox else { return }
            guard try configured() == operation.connection else { throw APIError.message("Restore the original Students connection to inspect this saved operation.") }
            let data = try await api.mobileData(connection: operation.connection, path: "/api/admin-messages/\(operation.requestID.uuidString)")
            try record(data, expected: operation.requestID)
            error = nil
        } catch {
            guard api.accessAllowed else { return }
            self.error = MobileRules.error(error) + " The send outcome remains unconfirmed. A missing result is not permission to resend."
        }
    }
    func boundedRecovery() async {
        for delay in [0, 2, 5, 10] {
            guard !Task.isCancelled && api.accessAllowed else { return }
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            await recover()
            guard let operation = state?.outbox, operation.result?.needsRecovery ?? true else { return }
        }
    }
    func reviewAndStartNew() {
        guard !busy else { return }
        do { try update { $0.outbox = nil }; notice = "Reviewed. Starting a new message requires a new confirmation. Nothing was resent." }
        catch { self.error = MobileRules.error(error) }
    }

    func event(_ id: UUID) async throws -> MobileEvent {
        guard capabilities?.supportsEvents == true else { throw APIError.message("Refresh to confirm event support first.") }
        let data = try await api.mobileData(connection: configured(), path: "/api/events/\(id.uuidString)")
        let value = try JSONDecoder().decode(MobileEvent.self, from: data)
        guard value.id == id, MobileRules.validPhone(value.phone) else { throw APIError.message("Event target is unavailable.") }
        return value
    }

    // Upgrade cleanup only: no permission prompts, token registration or alerts.
    func retireNotifications() async {
        guard api.accessAllowed && !pushBusy else { return }
        pushBusy = true
        defer { pushBusy = false }
        do {
            try ensureLoaded()
            try update { $0.pushEnabled = false; $0.queuedEvents = []; $0.handledEvents = [] }
            try await revoke()
        } catch {
            // Retain the old destination for a later authenticated cleanup attempt.
            // Never discard a pending message or replace connection credentials.
        }
    }
    private func revoke() async throws {
        guard let current = state, let old = current.registeredConnection else { return }
        let data = try await api.mobileData(connection: old, path: "/api/push/devices/\(current.installationID.uuidString)", method: "DELETE")
        guard try JSONDecoder().decode(StudentMutationAcknowledgement.self, from: data).ok else { throw APIError.message("Could not confirm device revocation. Connection settings were retained.") }
        try update { $0.registeredConnection = nil }
    }
    func prepareConnectionChange() async throws {
        guard !busy && !pushBusy && !api.actionBusy else { throw APIError.message("Wait for the current operation before changing Students settings.") }
        try ensureLoaded()
        guard state?.outbox == nil else { throw APIError.message("Review the saved message operation before changing Students server/account.") }
        pushBusy = true
        defer { pushBusy = false }
        try await revoke()
        try update { $0.pushEnabled = false; $0.drafts = [:]; $0.queuedEvents = []; $0.handledEvents = [] }
        generation += 1; capabilities = nil; capabilityConnection = nil; events = []
        api.invalidateStudentsConnection()
    }
}

