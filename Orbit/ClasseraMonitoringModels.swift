import Foundation

protocol ClasseraVersioned: Decodable { var version: Int { get } }
enum ClasseraDeliveryState {
    static let all = ["reserved", "accepted", "sent", "delivered", "read", "failed", "unknown"]
    static func title(_ value: String) -> String { all.contains(value) ? value.capitalized : "Unknown" }
}
struct ClasseraWaitingStudent: Decodable, Identifiable {
    let phone: String
    let name: String?
    let joined_at: String
    let notification_status: String
    let eligible: Bool
    var id: String { phone }
}
struct ClasseraReadyPreview: ClasseraVersioned, Identifiable {
    let version: Int
    let class_id: String
    let class_name: String
    let supported: Bool
    let revision: String
    let eligible_count: Int
    let waiting_count: Int
    let can_execute: Bool
    let disabled_reason: String?
    let students: [ClasseraWaitingStudent]
    let updated_at: Int
    var id: String { class_id }
}
struct ClasseraWaitingResponse: ClasseraVersioned {
    let version: Int
    let classes: [ClasseraReadyPreview]
    let updated_at: Int
    let sending_enabled: Bool
    let notice: String
}
struct ClasseraReadyPayload: Codable, Equatable {
    let request_id: String
    let class_id: String
    let expected_revision: String
    let expected_eligible_count: Int
    init(preview: ClasseraReadyPreview, requestID: String = UUID().uuidString.lowercased()) throws {
        guard preview.version == 1, preview.can_execute, preview.supported,
              preview.eligible_count > 0, preview.eligible_count == preview.students.filter(\.eligible).count,
              preview.revision.count == 64, preview.revision.allSatisfy({ $0.isHexDigit }),
              let uuid = UUID(uuidString: requestID), uuid.uuidString.lowercased() == requestID else {
            throw ClasseraMonitoringFailure.invalidResponse
        }
        request_id = requestID; class_id = preview.class_id
        expected_revision = preview.revision; expected_eligible_count = preview.eligible_count
    }
}
struct ClasseraReadyRecipient: Decodable, Identifiable {
    let phone: String
    let status: String
    let error_code: String?
    var id: String { phone }
}
struct ClasseraReadyOperation: ClasseraVersioned {
    let version: Int
    let request_id: String
    let class_id: String
    let status: String
    let created_at: Int
    let updated_at: Int
    let total: Int
    let counts: [String: Int]
    let recipients: [ClasseraReadyRecipient]
}
struct ClasseraDeliveryRecord: Decodable, Identifiable {
    let id: String
    let report: String
    let report_date: String?
    let report_date_source: String?
    var displayReportDate: String? { report_date ?? ClasseraReportTitleDate.parse(report) }
    var dateFromTitle: Bool { report_date_source == "title" || (report_date == nil && ClasseraReportTitleDate.parse(report) != nil) }
    let class_id: String
    let phone: String
    let student: String?
    let template: String?
    let message_id: String?
    let status: String
    let created_at: Int?
    let updated_at: Int
    let historical: Bool
}
struct ClasseraHistoryResponse: ClasseraVersioned {
    let version: Int
    let records: [ClasseraDeliveryRecord]
    let total: Int
    let offset: Int
    let next_offset: Int?
    let updated_at: Int
    let limitations: [String]
}
struct ClasseraDailyRow: Decodable, Identifiable {
    let id: String
    let date: String
    let class_id: String
    let report: String
    let counts: [String: Int]
    let attempts: Int
    let expected: Int?
    let delivered_targets: Int?
    let not_attempted: Int?
    let skipped: Int?
    let delivery_rate: Double?
}
struct ClasseraTemplateStatistics: Decodable, Identifiable {
    let id: String
    let template: String?
    let attempts: Int
    let counts: [String: Int]
    var title: String { template?.isEmpty == false ? template! : "Not recorded" }
}
struct ClasseraStatisticsResponse: ClasseraVersioned {
    let version: Int
    let from: String
    let to: String
    let updated_at: Int
    let reports: [ClasseraDailyRow]
    let templates: [ClasseraTemplateStatistics]?
    let counts: [String: Int]
    let attempts: Int
    let expected: Int?
    let delivered_targets: Int?
    let not_attempted: Int?
    let skipped: Int?
    let delivery_rate: Double?
    let unknown_date_records: Int
    let limitations: [String]
}
enum ClasseraMonitoringFailure: Error, LocalizedError {
    case invalidResponse, notSent, uncertain, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The monitoring response is incompatible. Refresh before taking any action."
        case .notSent: return "No notification request was submitted."
        case .uncertain: return "The outcome is uncertain. Check the saved operation status; do not submit another notification."
        case .http(let status, let code):
            if code == "sending_disabled" { return "Class-ready invitations are not enabled on this server." }
            switch status {
            case 401, 403: return "Owner authentication failed. Check Orbit connection settings."
            case 404: return "This feature or operation was not found. A missing operation after a connection error is not permission to resend."
            case 409: return "The preview changed or this invitation is already reserved. Refresh and review before any new action."
            case 422: return "Check the selected filters or notification preview."
            case 429: return "Rate limit reached. No request was retried."
            case 300...399: return "Redirect refused. Check the configured Orbit HTTPS address."
            default: return "Classera monitoring is unavailable. No notification was retried."
            }
        }
    }
}

enum ClasseraReportTitleDate {
    static func parse(_ title: String) -> String? {
        let pattern = #"(?:^|\D)(\d{1,2})[_/-](\d{1,2})[_/-](\d{4}|\d{2})(?:\D|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
        let pieces = (1...3).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: title) else { return nil }
            return Int(title[range])
        }
        guard pieces.count == 3 else { return nil }
        let year = pieces[2] < 100 ? 2000 + pieces[2] : pieces[2]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let wanted = DateComponents(year: year, month: pieces[1], day: pieces[0])
        guard let date = calendar.date(from: wanted) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year && actual.month == pieces[1] && actual.day == pieces[0] else { return nil }
        return String(format: "%04d-%02d-%02d", year, pieces[1], pieces[0])
    }
}
