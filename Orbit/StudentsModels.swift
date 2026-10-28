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
    private let activityStatusValue: String?
    var activityStatus: StudentActivityStatus { StudentActivityStatus(rawValue: activityStatusValue ?? "") ?? .unknown }

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
        case activityStatusValue = "activity_status"
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
    func removing(phone: String) -> StudentsSnapshot {
        StudentsSnapshot(students: students.filter { $0.phone != phone }, receivedAt: receivedAt, receivedInstant: receivedInstant)
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
    func windowLabel(for student: Student, at now: ContinuousClock.Instant = .now, timeZone: TimeZone = .current) -> String {
        guard isWindowOpen(for: student, at: now) else { return "Window closed" }
        let deadline = student.lastInboundDate?.addingTimeInterval(86400)
            ?? receivedAt.addingTimeInterval(Double(max(0, student.secondsLeft)))
        guard let clock = WindowClock.time(deadline, timeZone: timeZone) else { return "Window open · closing time unavailable" }
        return "Open until " + clock
    }
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

enum StudentsDirectory {
    static func countLabel(_ count: Int) -> String { "\(count) \(count == 1 ? "student" : "students")" }
    static func grades(in students: [Student]) -> [String] {
        Array(Set(students.filter { $0.state == "active" }.compactMap(\.grade).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func filtered(_ snapshot: StudentsSnapshot, search: String, filter: StudentsFilter,
                         grade: String, at now: ContinuousClock.Instant = .now) -> [Student] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.students.filter { student in
            guard query.isEmpty || (student.name?.localizedCaseInsensitiveContains(query) ?? false) || student.phone.contains(query) else { return false }
            switch filter {
            case .all: return true
            case .open: return snapshot.isWindowOpen(for: student, at: now)
            case .closed: return !snapshot.isWindowOpen(for: student, at: now)
            case .grade: return student.state == "active" && (grade.isEmpty || student.grade == grade)
            }
        }
    }
}

enum StudentActivityStatus: String {
    case allowed, suspended, blocked, unknown
    // Decode legacy restrictions without silently allowing those students.
    // The administrator now sees one reversible pause state.
    var title: String { self == .blocked ? "Suspended" : rawValue.capitalized }
    func matches(_ filter: StudentActivityStatus?) -> Bool {
        filter == nil || self == filter || (filter == .suspended && self == .blocked)
    }
}

enum StudentManagementAction: String, Identifiable, CaseIterable {
    case remove, block, unblock, suspend, resume
    var id: String { rawValue }
    var title: String {
        switch self {
        case .remove: return "Remove student"
        case .block: return "Block"
        case .unblock: return "Unblock"
        case .suspend: return "Suspend"
        case .resume: return "Resume"
        }
    }
    var activityStatus: StudentActivityStatus? {
        switch self {
        case .remove: return nil
        case .block: return .blocked
        case .suspend: return .suspended
        case .unblock, .resume: return .allowed
        }
    }
    var explanation: String {
        switch self {
        case .remove: return "Remove this student's profile and activity restriction? Messaging the bot again starts onboarding. Already sent messages cannot be recalled."
        case .block: return "Block this student? The server must stop bot replies until you unblock them. Their profile is preserved."
        case .unblock: return "Unblock this student and allow bot replies again? Onboarding and the WhatsApp messaging window still apply."
        case .suspend: return "Pause outgoing messages from this student database until you choose Resume? The profile and onboarding progress are preserved. Messages already submitted to WhatsApp cannot be recalled."
        case .resume: return "Allow messages from this student database again? Normal onboarding, opt-in and WhatsApp messaging-window rules still apply."
        }
    }
    func isValid(for status: StudentActivityStatus) -> Bool {
        switch self {
        case .remove: return status != .unknown
        case .block: return status == .allowed || status == .suspended
        case .unblock: return status == .blocked
        case .suspend: return status == .allowed
        case .resume: return status == .suspended || status == .blocked
        }
    }
    static func available(for status: StudentActivityStatus) -> [StudentManagementAction] {
        switch status {
        case .allowed: return [.suspend, .remove]
        case .suspended, .blocked: return [.resume, .remove]
        case .unknown: return []
        }
    }
}

struct StudentActivityPayload: Encodable {
    let activityStatus: String
    enum CodingKeys: String, CodingKey { case activityStatus = "activity_status" }
}
struct StudentMutationAcknowledgement: Decodable { let ok: Bool }
enum StudentMutationFailure: Error { case notSent, authorizationFailed, uncertain }




enum WindowClock {
    static func time(_ date: Date, timeZone: TimeZone = .current) -> String? {
        guard date.timeIntervalSince1970.isFinite, (0...253402300799).contains(date.timeIntervalSince1970) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
