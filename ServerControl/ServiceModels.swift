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
    }

    let kind: Kind
    let id: String
    let name: String

    var title: String {
        switch kind {
        case .testGeminiKey:
            return "Test \(name)?"

        case .fireClasseraReport:
            return "Send WhatsApp report?"

        case .forceFireClasseraReport:
            return "Force-send WhatsApp report?"
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
        }
    }
}
