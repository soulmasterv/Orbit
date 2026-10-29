import Foundation

struct LatestClasseraReportsResponse: Decodable {
    static let classes = ["12F", "12E"]
    let version: Int
    let status: String
    let results: [LatestClasseraReport]

    enum CodingKeys: String, CodingKey { case version, status, results }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        status = try values.decode(String.self, forKey: .status)
        results = try values.decodeIfPresent([LatestClasseraReport].self, forKey: .results) ?? []
    }

    var isValid: Bool {
        version == 1 && ["available", "partial", "unavailable"].contains(status) &&
        results.count <= 2 && Set(results.map(\.classID)).count == results.count &&
        results.allSatisfy { row in
            Self.classes.contains(row.classID) &&
            (row.status == nil || ["available", "unavailable"].contains(row.status!)) &&
            (row.availability == nil || row.availability == "last_observed") &&
            (row.source == nil || row.source == "log")
        }
    }

    func report(for classID: String) -> LatestClasseraReport? {
        results.first { $0.classID == classID }
    }

    var observedCount: Int { results.filter(\.hasObservation).count }
}

struct LatestClasseraReport: Decodable, Identifiable {
    let classID: String
    let status: String?
    let availability: String?
    let title: String?
    let classeraCreatedAt: String?
    let logObservedAt: String?
    let timestampTimezone: String?
    let source: String?
    let attachmentID: String?
    let recordedSent: Bool?
    let reason: String?
    var id: String { classID }

    enum CodingKeys: String, CodingKey {
        case status, availability, title, source, reason
        case classID = "class_id", classeraCreatedAt = "classera_created_at"
        case logObservedAt = "log_observed_at", timestampTimezone = "timestamp_timezone"
        case attachmentID = "attachment_id", recordedSent = "recorded_sent"
    }

    var hasObservation: Bool {
        status == "available" && availability == "last_observed" && source == "log" &&
        title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // Preserve the recorded wall-clock strings: unknown timezone means no conversion.
    var createdText: String { Self.recordedText(classeraCreatedAt) }
    var observedText: String { Self.recordedText(logObservedAt) }
    var timezoneText: String {
        guard let timezone = timestampTimezone, !timezone.isEmpty else { return "Timezone not verified" }
        return "Recorded timezone: \(timezone)"
    }
    private static func recordedText(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "Not recorded" }
        return text
    }
}

enum LatestClasseraReportsFailure: Error, Equatable {
    case authenticationRequired, invalidResponse, endpointUnavailable
}

enum LatestClasseraReportsState: Equatable {
    case idle, loading, ready, partial, unavailable, authenticationRequired, failed

    var message: String? {
        switch self {
        case .idle: return "Refresh to read previous observations from the bot logs."
        case .loading: return "Reading report observations…"
        case .ready: return nil
        case .partial: return "A reliable report observation is available for only one class."
        case .unavailable: return "No reliable report observations are available from the logs."
        case .authenticationRequired: return "Authentication failed. Check your server token in Settings."
        case .failed: return "Could not load report observations. Check your connection and refresh."
        }
    }
}
