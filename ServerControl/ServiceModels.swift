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

