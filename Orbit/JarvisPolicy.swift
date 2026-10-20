import Foundation

enum JarvisPolicy {
    static let home = URL(string: "https://jarvis.labbing.space/")!
    static let accessHost = "quiet-sky-4b47.cloudflareaccess.com"
    static func isAccessLogin(_ url: URL?) -> Bool {
        guard let url, let p = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return p.scheme?.lowercased() == "https" && p.host?.lowercased() == accessHost &&
            (p.port == nil || p.port == 443) && p.user == nil && p.password == nil &&
            p.path.hasPrefix("/cdn-cgi/access/")
    }
    static func isGoogleLogin(_ url: URL?) -> Bool {
        guard let url, let p = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return p.scheme?.lowercased() == "https" && p.host?.lowercased() == "accounts.google.com" &&
            (p.port == nil || p.port == 443) && p.user == nil && p.password == nil
    }
    static func loadFailure(_ error: Error) -> String? {
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: e.code) {
            case .cancelled: return nil
            case .timedOut: return "JARVIS timed out. Tap Reload to try again. (code \(e.code))"
            case .notConnectedToInternet, .dataNotAllowed:
                return "Orbit has no network access. Check iPhone Settings → Cellular → Orbit and your Wi-Fi/VPN. (code \(e.code))"
            case .cannotFindHost, .dnsLookupFailed:
                return "Orbit could not resolve the JARVIS address. Check DNS or your VPN, then Reload. (code \(e.code))"
            case .cannotConnectToHost, .networkConnectionLost:
                return "Orbit could not keep a connection to JARVIS. Check the network, then Reload. (code \(e.code))"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "JARVIS HTTPS verification failed. Check the iPhone date/time and certificate configuration. (code \(e.code))"
            default: break
            }
        }
        // Do not display localizedDescription/userInfo: they may contain OAuth URLs or cookies.
        return "Orbit could not load JARVIS. Error code \(e.code). Send this code for diagnosis, then tap Reload."
    }
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
        if !ready || !authenticated { stop() }
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

