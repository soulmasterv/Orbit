import Foundation

struct MobileCapabilities: Decodable {
    let version: Int
    let onboarding_push: Bool
    let feedback_push: Bool
    let plain_text_messages: Bool
    let message_idempotency: Bool
    let push: PushReadiness
    struct PushReadiness: Decodable {
        let configured: Bool
        let environment: String
        let missing_settings: [String]?
    }
    var supportsMessages: Bool { version == 1 && plain_text_messages && message_idempotency }
    var supportsEvents: Bool { version == 1 && (onboarding_push || feedback_push) }
}

struct MobileEvent: Decodable, Identifiable, Hashable {
    let id: UUID
    let kind: String
    let phone: String
    let feedback_id: Int?
    let created_at: Int
    var title: String { kind == "onboarding_completed" ? "Student onboarded" : "Answer flagged" }
}

struct AdminMessage: Codable {
    let request_id: UUID
    let phone: String
    let status: String
    let wa_id: String?
    let error_code: String?
    let created_at: Int
    let updated_at: Int
    let pricing: MessagePricing?
    var awaitsReadReceipt: Bool { !["read", "failed", "cancelled"].contains(status) }
    var needsRecovery: Bool { ["pending", "unknown", "accepted", "sent"].contains(status) }
    var needsReview: Bool { !["accepted", "sent", "delivered", "read", "failed", "cancelled"].contains(status) }
    var explanation: String {
        switch status {
        case "pending": return "Pending. Dispatch may still be in progress. Do not resend."
        case "accepted": return "Accepted by Meta. Delivery has not been confirmed."
        case "sent": return "Sent. Delivery has not been confirmed."
        case "delivered": return "Delivery confirmed by the server's delivery webhook."
        case "read": return "Read confirmed by the server's delivery webhook."
        case "failed": return "The server recorded a failure. Review before creating another message."
        case "cancelled": return "Cancelled before dispatch because the profile, restriction or window changed."
        default: return "Outcome unknown. Check WhatsApp and review this operation before starting another message."
        }
    }
}

struct MessagePricing: Codable {
    let billable: Bool?
    let pricing_model: String?
    let category: String?
    let type: String?
    var summary: String {
        let values = [billable.map { $0 ? "Billable (Meta)" : "Not billable (Meta)" }, pricing_model, category, type].compactMap { $0 }
        return values.isEmpty ? "Pricing unknown" : values.joined(separator: " · ")
    }
}

struct PendingAdminMessage: Codable {
    let requestID: UUID
    let connection: StudentsConnection
    let phone: String
    let text: String
    var result: AdminMessage?
    var attempted = false
}

struct MobileSecureState: Codable {
    var installationID = UUID()
    // Legacy notification fields are decoded only for upgrade revocation. The
    // app never enables, registers or schedules notifications in this release.
    var pushEnabled = false
    // Keep the old destination until revocation succeeds, even after a crash.
    var registeredConnection: StudentsConnection?
    var outbox: PendingAdminMessage?
    var drafts: [String: String] = [:]
    var handledEvents: [UUID] = []
    var queuedEvents: [UUID] = []
}

enum MobileRules {
    static func validPhone(_ phone: String) -> Bool {
        !phone.isEmpty && phone.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func text(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...3500).contains(value.count) else { throw APIError.message("Enter 1–3500 characters.") }
        return value
    }
    static func canSend(_ student: Student, snapshot: StudentsSnapshot) -> Bool {
        student.state == "active" && student.activityStatus == .allowed && snapshot.isWindowOpen(for: student, at: .now)
    }
    static func error(_ error: Error) -> String {
        if let http = error as? HTTPFailure {
            switch http.status {
            case 401: return "Students API key rejected. Update Students connection settings."
            case 403: return "Access restricted. The student may be blocked or suspended."
            case 404: return "This record is missing, deleted or expired, or the feature is not deployed."
            case 409: return "Conflict: check the messaging window, onboarding or request identity."
            case 422: return "The server rejected the supplied values. Review your input."
            case 429: return "Server rate limit reached. No action was retried."
            case 300...399: return "Redirect refused. Check the configured HTTPS Students address."
            default: return "The server could not confirm the operation. No mutation was retried."
            }
        }
        if let safe = error as? APIError { return safe.errorDescription ?? "Operation unavailable." }
        if error is DecodingError { return "The server response is incompatible with this feature." }
        return "The connection was interrupted. A submitted action may have succeeded; check its saved status."
    }
}

struct FeedbackRecord: Decodable, Identifiable {
    let id: Int
    let phone: String
    let note: String
    let question: String
    let answer: String
    let ts: Int
    let resolved: Int
    var isResolved: Bool { resolved == 1 }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    static func decode(_ data: Data) throws -> [FeedbackRecord] {
        let rows = try JSONDecoder().decode([FeedbackRecord].self, from: data)
        guard rows.allSatisfy({ [0, 1].contains($0.resolved) }), Set(rows.map(\.id)).count == rows.count else {
            throw APIError.message("Feedback response is incompatible.")
        }
        return rows
    }
}

