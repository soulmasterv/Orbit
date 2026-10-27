import Foundation

struct ClasseraSubscription: Codable, Identifiable, Equatable {
    var className: String
    var name: String
    var aiEnabled: Int?
    var status: String
    var joinedAt: String?
    var updatedAt: String?
    var id: String { className }
    var editable: Bool { ["12F", "12E"].contains(className) }
    enum CodingKeys: String, CodingKey {
        case name, status
        case className = "class_name", aiEnabled = "ai_enabled", joinedAt = "joined_at", updatedAt = "updated_at"
    }
}
struct ClasseraSignup: Codable {
    let step: String
    let name: String?
    let className: String?
    enum CodingKeys: String, CodingKey { case step, name; case className = "class_name" }
}
struct ClasseraStudent: Codable, Identifiable {
    let phone: String
    let subscriptions: [ClasseraSubscription]
    let signupSession: ClasseraSignup?
    let revision: String
    let whatsappWindows: [ClasseraWhatsAppWindow]?
    private let activityStatusValue: String?
    var activityStatus: StudentActivityStatus { StudentActivityStatus(rawValue: activityStatusValue ?? "") ?? .unknown }
    var id: String { phone }
    var displayName: String { subscriptions.first?.name ?? signupSession?.name ?? "Onboarding student" }
    var maskedPhone: String { "•••• " + phone.suffix(4) }
    var hasPendingClass: Bool { subscriptions.contains { $0.status == "waiting_for_class" } }
    enum CodingKeys: String, CodingKey { case phone, subscriptions, revision; case signupSession = "signup_session", activityStatusValue = "activity_status", whatsappWindows = "whatsapp_windows" }
}

enum ClasseraNameEdit {
    static func applying(_ input: String, to rows: [ClasseraSubscription]) throws -> [ClasseraSubscription] {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              rows.contains(where: \.editable) else {
            throw APIError.message("Enter a name of 1–120 characters for an existing supported subscription.")
        }
        return rows.map { row in
            var updated = row
            if updated.editable { updated.name = name }
            return updated
        }
    }
}
struct ClasseraDirectoryResponse: Decodable { let version: Int; let students: [ClasseraStudent] }
struct ClasseraSubscriptionEdit: Encodable {
    let className: String
    let name: String
    let aiEnabled: Int?
    let status: String
    enum CodingKeys: String, CodingKey { case name, status; case className = "class_name", aiEnabled = "ai_enabled" }
    // Explicit null is required for an unknown AI preference.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(className, forKey: .className); try c.encode(name, forKey: .name)
        try c.encode(aiEnabled, forKey: .aiEnabled); try c.encode(status, forKey: .status)
    }
}
struct ClasseraStudentEdit: Encodable {
    let expectedRevision: String
    let subscriptions: [ClasseraSubscriptionEdit]
    enum CodingKeys: String, CodingKey { case expectedRevision = "expected_revision", subscriptions }
    init(student: ClasseraStudent, rows: [ClasseraSubscription]) throws {
        let known = rows.filter(\.editable)
        guard student.signupSession == nil, student.revision.count == 64,
              Set(known.map(\.className)).count == known.count,
              known.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 &&
                  !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                  ["active", "waiting_for_class"].contains($0.status) &&
                  ($0.aiEnabled == nil || $0.aiEnabled == 0 || $0.aiEnabled == 1) &&
                  ($0.status != "waiting_for_class" || $0.aiEnabled == nil) }) else {
            throw APIError.message("Enter a name for each class. Finish any WhatsApp signup before editing here.")
        }
        expectedRevision = student.revision
        subscriptions = known.map { ClasseraSubscriptionEdit(className: $0.className, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), aiEnabled: $0.aiEnabled, status: $0.status) }
    }
}
enum ClasseraDirectoryFailure: Error, Equatable { case conflict, uncertain }
struct ClasseraManagementPayload: Encodable {
    let expectedRevision: String
    let activityStatus: String?
    enum CodingKeys: String, CodingKey { case expectedRevision = "expected_revision", activityStatus = "activity_status" }
}
enum ClasseraClass {
    static func title(_ value: String) -> String {
        switch value {
        case "12F", "classera-1": return "Classera 1 (F)"
        case "12E", "classera-2": return "Classera 2 (E)"
        default: return value
        }
    }
}


enum ClasseraSubscriptionSummary {
    static func aiLabel(_ row: ClasseraSubscription) -> String {
        guard row.status != "waiting_for_class" else { return "Not set" }
        switch row.aiEnabled { case 1: return "On"; case 0: return "Off"; default: return "Not set" }
    }
}

/// Optional read-only capability. Missing data is never inferred from signup,
/// subscription updates, delivery/read receipts or the school-assistant database.
struct ClasseraWhatsAppWindow: Codable, Identifiable {
    let className: String
    let windowOpen: Bool?
    let secondsLeft: Int?
    let lastInboundAt: Int?
    var id: String { className }
    enum CodingKeys: String, CodingKey {
        case className = "class_name", windowOpen = "window_open"
        case secondsLeft = "seconds_left", lastInboundAt = "last_inbound_at"
    }
    func remainingSeconds(since received: ContinuousClock.Instant, at now: ContinuousClock.Instant = .now) -> TimeInterval? {
        guard let open = windowOpen, let seconds = secondsLeft, (0...86400).contains(seconds),
              let inbound = lastInboundAt, inbound > 0 else { return nil }
        if !open { return seconds == 0 ? 0 : nil }
        let elapsed = received.duration(to: now).components
        let duration = max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        return max(0, Double(seconds) - duration)
    }
    func label(since received: ContinuousClock.Instant, at now: ContinuousClock.Instant = .now) -> String {
        guard let seconds = remainingSeconds(since: received, at: now) else { return "Unavailable" }
        guard seconds > 0 else { return "Closed" }
        let minutes = Int(ceil(seconds / 60))
        return String(format: "Open · %02ld:%02ld", minutes / 60, minutes % 60)
    }
}
