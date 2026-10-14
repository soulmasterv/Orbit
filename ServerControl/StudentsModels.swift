import Foundation

struct StudentsConnection: Codable, Equatable {
    let baseURL: String
    let apiKey: String

    @MainActor func validated() throws -> StudentsConnection {
        let url = try ServerAPI.validatedBaseURL(baseURL)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw APIError.message("Enter a non-empty Students API key without line breaks.")
        }
        return StudentsConnection(baseURL: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), apiKey: key)
    }
}

struct Student: Decodable, Identifiable {
    let phone: String
    let name: String?
    let grade: String?
    let state: String
    let windowOpen: Bool
    let secondsLeft: Int
    // Older servers can omit these fields. Values are Unix epoch seconds UTC.
    let firstSeen: Int?
    let lastInboundAt: Int?

    var id: String { phone }
    var displayName: String { provided(name) }
    var displayGrade: String { provided(grade) }
    var gradeLabel: String {
        guard let grade, !grade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Not provided yet" }
        return "Grade \(grade)"
    }
    var firstSeenDate: Date? { firstSeen.map { Date(timeIntervalSince1970: Double($0)) } }
    var lastInboundDate: Date? { lastInboundAt.map { Date(timeIntervalSince1970: Double($0)) } }
    var maskedPhone: String { phone.count > 4 ? String(repeating: "•", count: phone.count - 4) + String(phone.suffix(4)) : "••••" }
    var stateLabel: String { state.replacingOccurrences(of: "_", with: " ").capitalized }

    enum CodingKeys: String, CodingKey {
        case phone, name, grade, state
        case windowOpen = "window_open", secondsLeft = "seconds_left"
        case firstSeen = "first_seen", lastInboundAt = "last_inbound_at"
    }
    private func provided(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Not provided yet" }
        return value
    }
}

struct StudentsSnapshot {
    let students: [Student]
    let receivedAt: Date
    private let receivedInstant: ContinuousClock.Instant

    init(students: [Student], receivedAt: Date, receivedInstant: ContinuousClock.Instant = ContinuousClock.now) {
        self.students = students
        self.receivedAt = receivedAt
        self.receivedInstant = receivedInstant
    }

    func remainingSeconds(for student: Student, at now: ContinuousClock.Instant = ContinuousClock.now) -> TimeInterval {
        guard student.windowOpen else { return 0 }
        // A monotonic clock prevents device wall-clock changes from extending a window.
        // Every server refresh creates a new snapshot and resets this baseline.
        let elapsed = receivedInstant.duration(to: now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return max(0, Double(max(0, student.secondsLeft)) - max(0, seconds))
    }
    func isWindowOpen(for student: Student, at now: ContinuousClock.Instant = ContinuousClock.now) -> Bool { remainingSeconds(for: student, at: now) > 0 }
    func countdown(for student: Student, at now: ContinuousClock.Instant = ContinuousClock.now) -> String {
        let minutes = min(ceil(remainingSeconds(for: student, at: now) / 60), Double(Int.max / 60))
        let total = Int(minutes)
        return String(format: "%02ld:%02ld", total / 60, total % 60)
    }
}

enum StudentsFilter: String, CaseIterable, Identifiable {
    case all = "All", open = "Window open", closed = "Window closed", grade = "Grade"
    var id: String { rawValue }
}
