import Foundation

struct ReadSnapshotFreshness {
    static let lifetime: Duration = .seconds(60)
    private var received: ContinuousClock.Instant?
    private var context: UUID?
    func belongs(to context: UUID) -> Bool { self.context == context }
    func isFresh(context: UUID, at now: ContinuousClock.Instant = .now) -> Bool {
        guard self.context == context, let received else { return false }
        let elapsed = received.duration(to: now)
        return elapsed >= .zero && elapsed < Self.lifetime
    }
    mutating func record(context: UUID, at now: ContinuousClock.Instant = .now) {
        self.context = context; received = now
    }
    mutating func clear() { context = nil; received = nil }
    mutating func expire() { received = nil }
}
