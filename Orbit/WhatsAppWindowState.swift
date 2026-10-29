import Foundation

enum WhatsAppWindowState: Equatable {
    case unknown, closed, open(TimeInterval)
    static func evidence(open: Bool?, seconds: Int?, elapsed: TimeInterval) -> Self {
        guard let open else { return .unknown }
        if !open { return seconds == nil || seconds == 0 ? .closed : .unknown }
        guard let seconds, (0...86400).contains(seconds) else { return .unknown }
        let remaining = max(0, Double(seconds) - max(0, elapsed))
        return remaining > 0 ? .open(remaining) : .closed
    }
    var remaining: TimeInterval? {
        switch self { case .unknown: return nil; case .closed: return 0; case .open(let seconds): return seconds }
    }
    var isOpen: Bool { if case .open = self { return true }; return false }
}
