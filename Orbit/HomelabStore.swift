import Foundation
import Combine
import UIKit

enum FavoriteTarget: Hashable, Codable, Identifiable {
    case service(ServicePage), process(Int), docker(String)
    var id: String {
        switch self {
        case .service(let page): return "service:\(page.rawValue)"
        case .process(let id): return "process:\(id)"
        case .docker(let name): return "docker:\(name)"
        }
    }
}
struct ActivityEvent: Codable, Identifiable {
    enum Result: String, Codable { case accepted, failed, cancelled, uncertain }
    let id: UUID
    let date: Date
    let title: String
    let result: Result
    var detail: String {
        switch result {
        case .accepted: return "Accepted by the server • verify the latest status"
        case .failed: return "Not completed • check connection or authorization"
        case .cancelled: return "Cancelled before sending"
        case .uncertain: return "May have reached the server • verify before repeating"
        }
    }
}
@MainActor final class HomelabStore: ObservableObject {
    @Published private(set) var favorites: Set<FavoriteTarget>
    @Published private(set) var events: [ActivityEvent]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = defaults.data(forKey: "favorites.v4").flatMap { try? JSONDecoder().decode(Set<FavoriteTarget>.self, from: $0) } ?? []
        events = defaults.data(forKey: "activity.v4").flatMap { try? JSONDecoder().decode([ActivityEvent].self, from: $0) } ?? []
        events = Array(events.prefix(100))
    }
    func toggle(_ target: FavoriteTarget) {
        if favorites.contains(target) { favorites.remove(target) } else { favorites.insert(target) }
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites.v4")
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func record(title: String, result: ActivityEvent.Result, date: Date = .now) {
        // Store descriptions only, never request/response bodies, tokens, error text or logs.
        events.insert(ActivityEvent(id: UUID(), date: date, title: String(title.prefix(160)), result: result), at: 0)
        events = Array(events.prefix(100))
        defaults.set(try? JSONEncoder().encode(events), forKey: "activity.v4")
    }
    func clearHistory() { events = []; defaults.removeObject(forKey: "activity.v4") }
}

enum HumanTime {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func label(_ value: String?, now: Date = .now) -> String {
        guard let date = parse(value) else { return "Not reported" }
        return label(date, now: now)
    }
    static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed >= 0 && elapsed < 60 { return "Just now" }
        if elapsed >= 60 && elapsed < 3600 { return "\(Int(elapsed / 60)) min ago" }
        let formatter = DateFormatter(); formatter.locale = .current
        if calendar.isDate(date, inSameDayAs: now) { formatter.dateFormat = "h:mm a"; return "Today, \(formatter.string(from: date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}
