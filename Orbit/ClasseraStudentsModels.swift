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
    private let activityStatusValue: String?
    var activityStatus: StudentActivityStatus { StudentActivityStatus(rawValue: activityStatusValue ?? "") ?? .unknown }
    var id: String { phone }
    var displayName: String { subscriptions.first?.name ?? signupSession?.name ?? "Onboarding student" }
    var maskedPhone: String { "•••• " + phone.suffix(4) }
    var hasPendingClass: Bool { subscriptions.contains { $0.status == "waiting_for_class" } }
    enum CodingKeys: String, CodingKey { case phone, subscriptions, revision; case signupSession = "signup_session", activityStatusValue = "activity_status" }
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

