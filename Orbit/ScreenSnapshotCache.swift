import Foundation

/// Memory-only read snapshots. Authentication contexts never share entries.
@MainActor
final class ScreenSnapshotCache<Value> {
    private struct Entry {
        let value: Value
        var freshness: ReadSnapshotFreshness
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity = 16

    func value(for key: String, context: UUID, freshOnly: Bool = false, at now: ContinuousClock.Instant = .now) -> Value? {
        guard let entry = entries[key], entry.freshness.belongs(to: context),
              !freshOnly || entry.freshness.isFresh(context: context, at: now) else { return nil }
        return entry.value
    }
    func record(_ value: Value, for key: String, context: UUID, at now: ContinuousClock.Instant = .now) {
        var freshness = ReadSnapshotFreshness(); freshness.record(context: context, at: now)
        entries[key] = Entry(value: value, freshness: freshness)
        order.removeAll { $0 == key }; order.append(key)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
    }
    func clear() { entries.removeAll(); order.removeAll() }
}
