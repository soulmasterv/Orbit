import Foundation

struct AIKeyUsageResponse: Decodable, ClasseraVersioned {
    let version: Int
    let state: String
    let timezone: String
    let days: Int
    let class_name: String
    let updated_at: Int
    let configured_keys: Int
    let active_keys_today: Int
    let requests_today: Int
    let rate_limits_today: Int
    let chart_days: Int
    let daily: [AIKeyDailyUsage]
    let keys: [AIKeyUsageRow]
    let recommendation: String
    let unmapped_keys: Int

    var isValid: Bool {
        version == 1 && ["waiting", "ready"].contains(state) && timezone == "Africa/Cairo" &&
        [1, 7, 30].contains(days) && ["All", "12F", "12E"].contains(class_name) &&
        configured_keys >= 0 && active_keys_today >= 0 && active_keys_today <= configured_keys &&
        requests_today >= 0 && rate_limits_today >= 0 && rate_limits_today <= requests_today &&
        [7, 30].contains(chart_days) && unmapped_keys >= 0 &&
        Set(keys.map(\.id)).count == keys.count && keys.allSatisfy { $0.isValid } &&
        keys.filter(\.configured).count == configured_keys &&
        daily.allSatisfy { point in point.requests >= 0 && keys.contains { $0.id == point.key_id } }
    }
}

struct AIKeyUsageRow: Decodable, Identifiable {
    let id: String
    let label: String
    let configured: Bool
    let requests: Int
    let successful: Int
    let failed: Int
    let rate_limits: Int
    let last_used: String?
    var isValid: Bool {
        id.range(of: #"^(key|unmapped)-[1-9][0-9]*$"#, options: .regularExpression) != nil &&
        label == displayName && requests >= 0 && successful >= 0 && failed >= 0 &&
        successful + failed == requests && rate_limits >= 0 && rate_limits <= failed
    }
    var displayName: String {
        let number = id.split(separator: "-").last.map(String.init) ?? "?"
        return id.hasPrefix("key-") ? "Key \(number)" : "Unmapped key \(number)"
    }
}

struct AIKeyDailyUsage: Decodable, Identifiable {
    let day: String
    let key_id: String
    let label: String
    let requests: Int
    var id: String { "\(day)|\(key_id)" }
    var shortDay: String { String(day.suffix(5)) }
}
