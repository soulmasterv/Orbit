import Foundation
import Combine

struct InternetTrackerSnapshot: Decodable {
    struct Line: Decodable, Identifiable {
        let slot: Int; let number: String?; let provider: String?; let weekly: Bool
        let nextAt: Double?; let channel: String?
        var id: Int { slot }
    }
    struct Amount: Decodable { let amount: String; let unit: String }
    struct Event: Decodable, Identifiable {
        let id: String; let eventId: String?; let at: Double?; let number: String
        let provider: String; let status: String; let remaining: [Amount]?
        let recordingAvailable: Bool; let recordingExpired: Bool; let channel: String
        var pending: Bool { ["queued", "running"].contains(status) }
        var hasAllowance: Bool {
            guard let remaining, (1...2).contains(remaining.count) else { return false }
            return remaining.allSatisfy { ["GB","MB"].contains($0.unit) && $0.amount.range(of: #"^\d{1,6}(?:\.\d{1,3})?$"#, options: .regularExpression) != nil }
        }
        var allowance: String {
            guard hasAllowance, let remaining else { return "Couldn’t read the remaining allowance." }
            return remaining.map { "\($0.amount) \($0.unit)" }.joined(separator: " + ") + " remaining"
        }
        func expired(now: Date = Date()) -> Bool {
            recordingExpired || (at.map { now.timeIntervalSince1970 * 1000 - $0 >= 7*86400000 } ?? true)
        }
    }
    let version: Int; let phone: String; let allowed: Bool; let permissionGranted: Bool
    let permissionEditable: Bool; let friendChecksEnabled: Bool; let revision: String
    let policy: String; let audioProvider: String; let lines: [Line]; let pending: Bool
    let history: [Event]; let operation: String?
}

struct InternetTrackerChange: Encodable, Identifiable {
    let request_id: String
    let action: String; let revision: String
    var slot: Int? = nil; var number: String? = nil; var provider: String? = nil
    var enabled: Bool? = nil; var channel: String? = nil; var policy: String? = nil
    var confirmed: Bool? = nil
    var id: String { request_id }
    init(action: String, revision: String) {
        request_id = UUID().uuidString.lowercased(); self.action = action; self.revision = revision
    }
    var mayStartCheck: Bool { action == "check" || (action == "schedule" && enabled == true) }
    var valid: Bool {
        guard UUID(uuidString: request_id) != nil, revision.count == 64 else { return false }
        if action == "permission" { return enabled != nil }
        guard [1,2].contains(slot ?? 0) else { return false }
        if action == "delete_line" { return true }
        if action == "line" { return InternetTrackerFormat.landline(number ?? "") != nil && ["vodafone","we"].contains(provider ?? "") }
        if action == "schedule" && enabled == false { return true }
        return mayStartCheck && ["sms","whatsapp"].contains(channel ?? "") && confirmed == true && !(policy ?? "").isEmpty
    }
}

enum InternetTrackerFormat {
    static func phone(_ value: String) -> String? { OrbitCallerNumber.normalized(value).map { String($0.dropFirst()) } }
    static func landline(_ input: String) -> String? {
        guard input.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "+0123456789 ()-").contains($0) }) else { return nil }
        var n = OrbitPhoneNumberField.removingFormatting(input)
        if n.hasPrefix("+20") { n = "0" + n.dropFirst(3) }
        else if n.hasPrefix("0020") { n = "0" + n.dropFirst(4) }
        return n.range(of: #"^0[2-9][0-9]{7,8}$"#, options: .regularExpression) == nil ? nil : n
    }
    static func provider(_ value: String?) -> String { value == "we" ? "WE" : value == "vodafone" ? "Vodafone" : "Not set" }
    static func time(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "Unavailable" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Africa/Cairo")
        f.dateFormat = "d MMM, h:mm a"; return f.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
    static func status(_ value: String) -> String {
        switch value {
        case "queued": "Queued"
        case "running": "Running"
        case "completed": "Result"
        case "failed": "Failed"
        case "access_revoked": "Permission removed"
        case "expired": "Check expired"
        case "provider_changed": "Service changed"
        default: "Unconfirmed"
        }
    }
}

enum InternetRecordingFiles {
    static func remove(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard UUID(uuidString: folder.lastPathComponent) != nil,
              folder.deletingLastPathComponent().lastPathComponent == "orbit-internet-recordings" else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor final class InternetTrackerStore: ObservableObject {
    @Published private(set) var value: InternetTrackerSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var inFlightID: String?
    private var generation = UUID()
    func clear() { generation = UUID(); value = nil; busy = false; uncertain = false; error = nil; notice = nil; inFlightID = nil }
    func load(_ fetch: () async throws -> InternetTrackerSnapshot) async {
        guard !busy else { return }; let epoch = generation; busy = true
        defer { if epoch == generation { busy = false } }
        do {
            let result = try await fetch(); guard epoch == generation, !Task.isCancelled else { return }
            guard result.version == 1 else { throw URLError(.cannotParseResponse) }
            value = result; uncertain = false; error = nil
        } catch {
            guard epoch == generation, !Task.isCancelled else { return }
            uncertain = true; self.error = "Internet Tracker could not be refreshed. Try again."
        }
    }
    func submit(_ change: InternetTrackerChange, send: (InternetTrackerChange) async throws -> InternetTrackerSnapshot) async -> Bool {
        guard !busy, !uncertain, change.valid, value?.revision == change.revision,
              !(value?.pending == true && (change.mayStartCheck || ["line","delete_line"].contains(change.action))) else { return false }
        let epoch = generation; busy = true; inFlightID = change.request_id
        defer { if epoch == generation { busy = false; inFlightID = nil } }
        do {
            let result = try await send(change); guard epoch == generation, !Task.isCancelled else { return false }
            guard result.version == 1 else { throw URLError(.cannotParseResponse) }
            value = result; error = nil
            switch result.operation {
            case "queued": notice = "Check queued."
            case "scheduled": notice = "Weekly checks enabled."
            case "saved": notice = "Saved."
            default: uncertain = true; notice = nil; error = "Submission could not be confirmed. Review history and refresh before trying again."
            }
            return !uncertain
        } catch {
            guard epoch == generation, !Task.isCancelled else { return false }
            uncertain = true; self.error = "Submission could not be confirmed. Review history and refresh before trying again."
            return false
        }
    }
}

struct VnStatSnapshot: Decodable {
    struct Period: Decodable, Identifiable { let date: String; let rx: Double; let tx: Double; var id: String { date } }
    struct Interface: Decodable, Identifiable {
        let id: String; let name: String; let virtual: Bool; let updatedAt: Double?
        let rx: Double; let tx: Double; let days: [Period]; let months: [Period]
    }
    let version: Int; let interfaces: [Interface]
}
