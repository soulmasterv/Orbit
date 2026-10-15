import Foundation
import Combine
import UIKit

@MainActor
final class MobileStore: ObservableObject {
    @Published private(set) var capabilities: MobileCapabilities?
    @Published private(set) var events: [MobileEvent] = []
    @Published private(set) var state: MobileSecureState?
    @Published private(set) var busy = false
    @Published private(set) var pushBusy = false
    @Published private(set) var error: String?
    @Published var notice: String?
    @Published var destination: UUID?
    private let api: ServerAPI
    private let load: () throws -> MobileSecureState
    private let save: (MobileSecureState) throws -> Void
    private let connection: () throws -> StudentsConnection?
    private var generation = 0
    private var foregroundBusy = false
    private var lastRegisteredToken: String?
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
        generation += 1; capabilities = nil; events = []; destination = nil
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
        guard !busy && api.accessAllowed else { return }
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

    func queue(eventID: UUID) {
        do {
            try update {
                if !$0.handledEvents.contains(eventID) && !$0.queuedEvents.contains(eventID) { $0.queuedEvents.append(eventID) }
                $0.queuedEvents = Array($0.queuedEvents.suffix(100))
            }
            if destination == nil { destination = state?.queuedEvents.first }
        } catch { self.error = MobileRules.error(error) }
    }
    func completed(eventID: UUID) {
        do { try update {
            $0.queuedEvents.removeAll { $0 == eventID }
            if !$0.handledEvents.contains(eventID) { $0.handledEvents.append(eventID) }
            $0.handledEvents = Array($0.handledEvents.suffix(500))
        } } catch { self.error = MobileRules.error(error) }
    }
    func event(_ id: UUID) async throws -> MobileEvent {
        guard capabilities?.supportsEvents == true else { throw APIError.message("Refresh to confirm event support first.") }
        let data = try await api.mobileData(connection: configured(), path: "/api/events/\(id.uuidString)")
        let value = try JSONDecoder().decode(MobileEvent.self, from: data)
        guard value.id == id, MobileRules.validPhone(value.phone) else { throw APIError.message("Event target is unavailable.") }
        return value
    }

    func setPushEnabled(_ enabled: Bool) async {
        guard !pushBusy && api.accessAllowed else { return }
        pushBusy = true
        defer { pushBusy = false }
        do {
            try ensureLoaded()
            if !enabled {
                try await revoke()
                try update { $0.pushEnabled = false }
                UIApplication.shared.unregisterForRemoteNotifications()
                notice = "Device registration removed. The event feed remains available."
                return
            }
            await refresh()
            guard capabilities?.supportsEvents == true else { throw APIError.message("Mobile push support is not deployed.") }
            await NotificationManager.shared.requestLocalPermission()
            guard NotificationManager.shared.permissionAllowed else { throw APIError.message("Notifications are denied. Enable them in iPhone Settings; the event feed still works.") }
            guard SignedPushIdentity.current() != nil else { throw APIError.message("This build has no readable signed APNs entitlement. A push-enabled Apple provisioning profile is required; SideStore signing may not support it.") }
            try update { $0.pushEnabled = true }
            UIApplication.shared.registerForRemoteNotifications()
            notice = "Requested an APNs token. Registration is complete only after the server acknowledges it."
        } catch { self.error = MobileRules.error(error) }
    }
    func syncPush(token: String, identity: SignedPushIdentity? = SignedPushIdentity.current(), permissionAllowed: Bool? = nil) async {
        guard !pushBusy && api.accessAllowed && !token.isEmpty else { return }
        pushBusy = true
        defer { pushBusy = false }
        do {
            try ensureLoaded()
            guard state?.pushEnabled == true, let identity,
                  permissionAllowed ?? NotificationManager.shared.permissionAllowed else { return }
            let configured = try configured()
            guard capabilityConnection == configured, let capabilities, capabilities.version == 1, capabilities.supportsEvents else { return }
            guard capabilities.push.environment == identity.environment else { throw APIError.message("APNs environment mismatch. Server and signed app must agree; registration was not sent.") }
            if state?.registeredConnection == configured && lastRegisteredToken == token { return }
            if state?.registeredConnection != nil && state?.registeredConnection != configured { try await revoke() }
            // Persist destination before PUT: a timeout must still be revocable.
            try update { $0.registeredConnection = configured }
            let topics = [(capabilities.onboarding_push ? "onboarding_completed" : nil), (capabilities.feedback_push ? "answer_flagged" : nil)].compactMap { $0 }
            let payload = PushDevicePayload(token: token, environment: identity.environment, topics: topics, enabled: true)
            guard let installation = state?.installationID else { throw CancellationError() }
            let data = try await api.mobileData(connection: configured, path: "/api/push/devices/\(installation.uuidString)",
                method: "PUT", body: JSONEncoder().encode(payload))
            guard try JSONDecoder().decode(StudentMutationAcknowledgement.self, from: data).ok else { throw APIError.message("Device registration was not acknowledged.") }
            lastRegisteredToken = token
            notice = capabilities.push.configured ? "Device registered. Delivery still requires valid Apple credentials and a running server worker; it is best effort." : "Device registered, but the server reports push signing settings missing. Delivery is not ready."
        } catch { self.error = MobileRules.error(error) }
    }
    private func revoke() async throws {
        guard let current = state, let old = current.registeredConnection else { return }
        let data = try await api.mobileData(connection: old, path: "/api/push/devices/\(current.installationID.uuidString)", method: "DELETE")
        guard try JSONDecoder().decode(StudentMutationAcknowledgement.self, from: data).ok else { throw APIError.message("Could not confirm device revocation. Connection settings were retained.") }
        try update { $0.registeredConnection = nil }
        lastRegisteredToken = nil
    }
    func prepareConnectionChange() async throws {
        guard !busy && !pushBusy else { throw APIError.message("Wait for the current operation before changing Students settings.") }
        try ensureLoaded()
        guard state?.outbox == nil else { throw APIError.message("Review the saved message operation before changing Students server/account.") }
        pushBusy = true
        defer { pushBusy = false }
        try await revoke()
        try update { $0.pushEnabled = false; $0.drafts = [:]; $0.queuedEvents = []; $0.handledEvents = [] }
        generation += 1; capabilities = nil; capabilityConnection = nil; events = []
    }
}
