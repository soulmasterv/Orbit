import Foundation

enum JarvisPolicy {
    static let home = URL(string: "https://jarvis.labbing.space/")!
    static func isOrigin(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && parts.host?.lowercased() == "jarvis.labbing.space" &&
            (parts.port == nil || parts.port == 443) && parts.user == nil && parts.password == nil
    }
    static func isCaptureOrigin(protocol scheme: String, host: String, port: Int) -> Bool {
        scheme == "https" && host.lowercased() == "jarvis.labbing.space" && (port == 0 || port == 443)
    }
}

/// A user gesture is consumed once. Backgrounding/navigation invalidates pending permission results.
struct JarvisCaptureGate {
    private(set) var generation = 0
    private(set) var ready = false
    private(set) var authenticated = false
    private(set) var foreground = false
    private(set) var armed = false
    mutating func update(version: Int, authenticated: Bool) {
        ready = version == 1; self.authenticated = authenticated
        if !ready || !authenticated { armed = false }
    }
    mutating func activate() { foreground = true }
    mutating func arm() { armed = ready && authenticated && foreground }
    mutating func consume() -> Int? {
        guard armed && ready && authenticated && foreground else { return nil }
        armed = false; return generation
    }
    func permits(_ attempt: Int) -> Bool { attempt == generation && ready && authenticated && foreground }
    mutating func stop(background: Bool = false) {
        generation += 1; armed = false
        if background { foreground = false }
    }
    mutating func resetDocument() {
        stop(); ready = false; authenticated = false
    }
}
