import Foundation

// Safe public schema: upstream credentials and raw monitor responses never belong here.
struct ServiceSnapshot: Codable {
    let geminiHealth: String?
    let gemini: [GeminiKeyStatus]?
    let classera: [ClasseraStatus]?
    let padel: [PadelComponent]?
}
struct GeminiKeyStatus: Codable, Identifiable {
    let id: String
    let name: String
    let status: String
    let lastAuthenticationCheck: String?
    let lastGenerationCheck: String?
    let canTest: Bool?
    var metadata: GeminiKeyMetadata? = nil
    enum CodingKeys: String, CodingKey { case id, name, status, lastAuthenticationCheck, lastGenerationCheck, canTest, metadata }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        lastAuthenticationCheck = try c.decodeIfPresent(String.self, forKey: .lastAuthenticationCheck)
        lastGenerationCheck = try c.decodeIfPresent(String.self, forKey: .lastGenerationCheck)
        canTest = try c.decodeIfPresent(Bool.self, forKey: .canTest)
        metadata = try? c.decode(GeminiKeyMetadata.self, forKey: .metadata)
        if metadata?.isValid != true { metadata = nil }
    }
    init(id: String, name: String, status: String, lastAuthenticationCheck: String? = nil, lastGenerationCheck: String? = nil, canTest: Bool? = nil, metadata: GeminiKeyMetadata? = nil) {
        self.id = id; self.name = name; self.status = status; self.lastAuthenticationCheck = lastAuthenticationCheck
        self.lastGenerationCheck = lastGenerationCheck; self.canTest = canTest; self.metadata = metadata
    }
}
struct GeminiKeyMetadata: Codable {
    let tag: String?
    let project: String?
    let configured_for: [String]
    let configuration_state: String
    let observed_in: [String]
    let usage_state: String
    let usage_days: Int
    var isValid: Bool {
        ["verified", "unavailable"].contains(configuration_state) && ["ready", "waiting", "unavailable"].contains(usage_state) &&
        usage_days == 30 && configured_for.allSatisfy { ["12F", "12E"].contains($0) } && observed_in.allSatisfy { ["12F", "12E"].contains($0) } &&
        [tag, project].compactMap { $0 }.allSatisfy { value in
            !value.isEmpty && value.count <= 64 && value.range(of: #"(?i)AIza|bearer|secret|token|password|[\p{Cc}]"#, options: .regularExpression) == nil
        }
    }
}
struct ClasseraAssessment: Codable, Identifiable {
    let date: String
    let label: String
    let type: String?
    let week: Int?
    let subjects: [String]?

    var id: String {
        "\(date)|\(label)"
    }
}

struct ClasseraAICacheItem: Codable, Identifiable {
    let hash: String
    let updatedAt: String?
    let hasSummary: Bool?
    let hasShortSummary: Bool?
    let hasExamMaterial: Bool?

    var id: String {
        hash
    }
}

struct ClasseraAICacheSummary: Codable {
    let count: Int?
    let recent: [ClasseraAICacheItem]?
}

struct ClasseraStatus: Codable, Identifiable {
    var displayName: String { ClasseraClass.title(id) }
    var recipients: [String]? = nil
    let id: String
    let name: String
    let status: String
    let schedulerStatus: String?
    let webhookStatus: String?
    let lastRun: String?
    let lastReport: String?
    let lastReportName: String?
    let upcomingAssessments: [ClasseraAssessment]?
    let aiCache: ClasseraAICacheSummary?
    let canFire: Bool?
    let canForceFire: Bool?
    let whatsappStatus: String?
    let sendingCount: Int?
    let acceptedCount: Int?
    let sentCount: Int?
    let deliveredCount: Int?
    let readCount: Int?
    let failedCount: Int?
    let unknownCount: Int?
    let latestDeliveryAt: String?
    let latestDeliveryReport: String?
}

struct PadelComponent: Codable, Identifiable {
    let id: String
    let name: String
    let status: String
    let deliveryStatus: String?
    let lastNotification: String?
}
struct ServiceCommand: Identifiable {
    enum Kind {
        case testGeminiKey
        case fireClasseraReport
        case forceFireClasseraReport
        case forceOneClasseraReport
    }

    let kind: Kind
    let id: String
    let name: String
    var recipient: String? = nil

    var title: String {
        switch kind {
        case .testGeminiKey:
            return "Test \(name)?"

        case .fireClasseraReport:
            return "Send WhatsApp report?"

        case .forceFireClasseraReport:
            return "Force-send WhatsApp report?"
        case .forceOneClasseraReport:
            return "Send to ONE PERSON ONLY?"
        }
    }

    var explanation: String {
        switch kind {
        case .testGeminiKey:
            return "Your server will test \(name). Its credentials stay on the server."

        case .fireClasseraReport:
            return "This asks \(name) to send the current report normally. Existing delivery protection remains enabled."

        case .forceFireClasseraReport:
            return "This bypasses the Classera delivery guard for this run and can resend a report that was already delivered. Confirm, then authorize on your iPhone."
        case .forceOneClasseraReport:
            return "Force-send the \(name) report to \(recipient ?? "") only. This can resend a previously delivered report. Confirm, then authorize on your iPhone."
        }
    }
}

struct ClasseraRecipientsResponse: Decodable {
    let ok: Bool
    let classera: String
    let recipients: [String]
}
struct ClasseraRecipientsPayload: Encodable { let recipients: [String] }
struct ClasseraForceOnePayload: Encodable { let recipient: String }

enum ClasseraRecipientValidation {
    static func number(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw APIError.message("Enter a non-empty phone number using digits only, including the country code.")
        }
        return clean
    }
    static func list(_ values: [String]) throws -> [String] {
        guard !values.isEmpty else { throw APIError.message("Add at least one recipient before saving.") }
        let clean = try values.map(number)
        guard Set(clean).count == clean.count else { throw APIError.message("Each recipient must appear only once.") }
        return clean
    }
}



