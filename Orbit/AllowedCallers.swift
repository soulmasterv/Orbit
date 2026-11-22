import Foundation
import Combine

enum OrbitIncomingMode: String, CaseIterable, Identifiable {
    case jarvis, silly, bibo, diaa
    case noqta = "diaa-noqta"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jarvis: "Private JARVIS"
        case .silly: "Hossam"
        case .bibo: "Bibo feeding call"
        case .diaa: "Diaa full playlist"
        case .noqta: "Noqta"
        }
    }
    static func title(_ mode: String) -> String { Self(rawValue: mode)?.title ?? mode }
}

enum OrbitCallerNumber {
    static func normalized(_ input: String) -> String? {
        guard input.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "+0123456789 ()-.").contains($0) }) else { return nil }
        var number = OrbitPhoneNumberField.removingFormatting(input)
        if number.hasPrefix("01"), number.count == 11 { number = "+20" + number.dropFirst() }
        else if number.hasPrefix("00") { number = "+" + number.dropFirst(2) }
        else if !number.hasPrefix("+") { number = "+" + number }
        guard number.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil else { return nil }
        return number
    }
}

struct OrbitAllowedCaller: Decodable, Identifiable, Equatable {
    let number: String
    let name: String
    let enabled: Bool
    let modes: [String]
    let defaultMode: String
    let selectedMode: String?
    var id: String { number }
    // The deployed API requires the owner to retain this mode and forbids it for guests.
    var isOwner: Bool { modes.contains("jarvis") }
    var currentMode: String { selectedMode ?? defaultMode }
    var displayName: String { name.isEmpty ? "Unnamed caller" : name }
}

struct OrbitAllowedCallers: Decodable {
    let version: Int
    let availableModes: [String]
    let callers: [OrbitAllowedCaller]
    var incomingOverride: OrbitIncomingOverride? = nil
    var availableOverrideModes: [String]? = nil
    enum CodingKeys: String, CodingKey {
        case version, availableModes, callers, availableOverrideModes
        case incomingOverride = "override"
    }
    var overrideModes: [String] {
        (availableOverrideModes ?? []).filter { $0 != "jarvis" && OrbitIncomingMode(rawValue: $0) != nil }
    }
}

struct OrbitIncomingOverride: Decodable, Equatable {
    let mode: String
    let expiresAt: Double
    var expires: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
    func remaining(at date: Date) -> Int { Int(max(0, min(999_999_999, ceil(expires.timeIntervalSince(date))))) }
    func countdown(at date: Date) -> String {
        let seconds = remaining(at: date)
        return seconds == 0 ? "Checking server expiry…" : String(format: "%d:%02d remaining", seconds / 60, seconds % 60)
    }
}

struct OrbitIncomingOverrideChange: Encodable {
    let action: String
    var mode: String? = nil
    var minutes: Int? = nil
    var isValid: Bool {
        if action == "clear_override" { return mode == nil && minutes == nil }
        return action == "override" && ["silly", "bibo", "diaa", "diaa-noqta"].contains(mode ?? "") && (1...120).contains(minutes ?? 0)
    }
    static func customMinutes(_ input: String) -> Int? {
        guard !input.isEmpty, input.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(input), (1...120).contains(value) else { return nil }
        return value
    }
}

struct OrbitCallerChange: Encodable {
    let action: String
    let number: String
    var name: String? = nil
    var enabled: Bool? = nil
    var modes: [String]? = nil
    var defaultMode: String? = nil
    // selectedMode intentionally absent: only the caller can reset their choice.
}

struct OrbitCallerDraft: Identifiable {
    let id = UUID()
    let original: OrbitAllowedCaller?
    var number: String
    var name: String
    var enabled: Bool
    var modes: Set<String>
    var defaultMode: String

    init(_ caller: OrbitAllowedCaller? = nil) {
        original = caller; number = caller?.number ?? ""; name = caller?.name ?? ""
        enabled = caller?.enabled ?? true; modes = Set(caller?.modes ?? [])
        defaultMode = caller?.defaultMode ?? ""
    }
    var isOwner: Bool { original?.isOwner == true }
    mutating func assign(_ mode: String, enabled: Bool) {
        guard mode != "jarvis" || (isOwner && enabled) else { return }
        if enabled { modes.insert(mode) } else { modes.remove(mode) }
        if !modes.contains(defaultMode) {
            defaultMode = OrbitIncomingMode.allCases.map(\.rawValue).first(where: { modes.contains($0) }) ?? ""
        }
    }
    func change(available: [String], existing: [OrbitAllowedCaller]) -> OrbitCallerChange? {
        guard let normalized = OrbitCallerNumber.normalized(number), name.count <= 80,
              !modes.isEmpty, modes.contains(defaultMode), modes.isSubset(of: Set(available)),
              modes.allSatisfy({ OrbitIncomingMode(rawValue: $0) != nil }) else { return nil }
        if let original {
            guard normalized == original.number, !isOwner || (enabled && modes.contains("jarvis")) else { return nil }
        } else {
            guard !modes.contains("jarvis"), !existing.contains(where: { $0.number == normalized }) else { return nil }
        }
        return OrbitCallerChange(action: "save", number: normalized, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 enabled: enabled, modes: OrbitIncomingMode.allCases.map(\.rawValue).filter { modes.contains($0) }, defaultMode: defaultMode)
    }
}

@MainActor final class OrbitAllowedCallersState: ObservableObject {
    @Published private(set) var snapshot: OrbitAllowedCallers?
    @Published private(set) var busy = false
    @Published private(set) var needsRefresh = false
    @Published private(set) var error: String?
    private var generation = UUID()
    func clear() { generation = UUID(); snapshot = nil; busy = false; needsRefresh = false; error = nil }
    func load(_ fetch: () async throws -> OrbitAllowedCallers) async {
        guard !busy else { return }
        let request = generation; busy = true
        defer { if request == generation { busy = false } }
        do {
            let result = try await fetch()
            guard request == generation, !Task.isCancelled else { return }
            guard result.version == 1 else { throw URLError(.cannotParseResponse) }
            snapshot = result; needsRefresh = false; error = nil
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            needsRefresh = true; self.error = "Could not load Allowed callers. Refresh to try again."
        }
    }
    func apply(_ send: () async throws -> OrbitAllowedCallers) async -> Bool {
        guard !busy, !needsRefresh, snapshot != nil else { return false }
        let request = generation; busy = true
        defer { if request == generation { busy = false } }
        do {
            let result = try await send()
            guard request == generation, !Task.isCancelled else { return false }
            guard result.version == 1 else { throw URLError(.cannotParseResponse) }
            snapshot = result; error = nil; return true
        } catch {
            guard request == generation, !Task.isCancelled else { return false }
            needsRefresh = true
            self.error = "Change could not be confirmed. Refresh before retrying; the previous settings are still shown."
            return false
        }
    }
}
