import Foundation
import Security

/// Deliberately not controlled by remote JSON or a user default.
enum JarvisAppSessionRollout {
    static let enabled = false
    // Add optional cookie names only after successful live Ubuntu proof.
    static let verifiedOptionalCookies: Set<String> = []
}

enum JarvisBootstrapError: Error, LocalizedError {
    case notVerified, busy, locked, invalidResponse, transport, http(Int)
    var errorDescription: String? {
        switch self {
        case .notVerified: return "Automatic JARVIS login is awaiting live backend verification."
        case .busy: return "A JARVIS session operation is already pending."
        case .locked: return "Unlock Orbit before connecting to JARVIS."
        case .invalidResponse: return "The JARVIS session response was rejected. No cookies were installed."
        case .transport: return "JARVIS session could not be confirmed. No request was retried."
        case .http(let status):
            switch status {
            case 401: return "Orbit API authentication was rejected. Check your saved server credential."
            case 403: return "The Orbit owner is not permitted to create this session."
            case 404: return "The JARVIS app-session endpoint is not deployed."
            case 409: return "JARVIS reported a nonce, device or session conflict."
            case 429: return "JARVIS session rate limit reached. No request was retried."
            case 503: return "JARVIS automatic-login prerequisites are unavailable."
            case 300...399: return "JARVIS session redirect refused. Check the Orbit API route."
            default: return "JARVIS could not confirm the session operation."
            }
        }
    }
}

struct JarvisSessionRequest: Encodable {
    let version = 1
    let installation_id: String
    let nonce: String
    init(installationID: UUID, nonce: String) {
        installation_id = installationID.uuidString.lowercased(); self.nonce = nonce
    }
    static func freshNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw JarvisBootstrapError.transport }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func validate() throws {
        guard (22...128).contains(nonce.utf8.count), nonce.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw JarvisBootstrapError.invalidResponse }
    }
}

private struct JarvisSessionEnvelope: Decodable {
    let version: Int
    let nonce: String
    let entry_url: String
    let expires_at: Int
    let cookies: [JarvisCookieEnvelope]
}
private struct JarvisCookieEnvelope: Decodable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let http_only: Bool
    let same_site: String
    let expires_at: Int
}

struct ValidatedJarvisAppSession: CustomStringConvertible, CustomDebugStringConvertible {
    let expiresAt: Date
    let entryURL: URL
    let cookies: [HTTPCookie]
    var description: String { "Validated JARVIS session (cookies redacted)" }
    var debugDescription: String { description }
    private init(expiresAt: Date, cookies: [HTTPCookie]) {
        self.expiresAt = expiresAt; self.cookies = cookies; entryURL = JarvisPolicy.home
    }
    static func decode(_ data: Data, expectedNonce: String, now: Date,
                       verifiedOptionalNames: Set<String> = JarvisAppSessionRollout.verifiedOptionalCookies) throws -> Self {
        do {
            guard data.count <= 65_536, verifiedOptionalNames.isSubset(of: ["CF_Binding", "CF_AppSession"]) else { throw JarvisBootstrapError.invalidResponse }
            let result = try JSONDecoder().decode(JarvisSessionEnvelope.self, from: data)
            let current = now.timeIntervalSince1970
            guard result.version == 1, result.nonce == expectedNonce,
                  result.entry_url == "https://jarvis.labbing.space/",
                  Double(result.expires_at) - current >= 60, Double(result.expires_at) - current <= 900,
                  (2...4).contains(result.cookies.count) else { throw JarvisBootstrapError.invalidResponse }
            let names = Set(result.cookies.map(\.name)), required: Set<String> = ["jarvis", "CF_Authorization"]
            guard names.count == result.cookies.count, required.isSubset(of: names),
                  names.isSubset(of: required.union(verifiedOptionalNames)) else { throw JarvisBootstrapError.invalidResponse }
            // Validate EVERY record before constructing or installing any cookie.
            for c in result.cookies {
                guard c.domain == "jarvis.labbing.space", c.path == "/", c.secure, c.http_only, c.same_site == "Strict",
                      Double(c.expires_at) > current, c.expires_at <= result.expires_at,
                      (1...8192).contains(c.value.utf8.count), c.value.utf8.allSatisfy({
                          $0 == 0x21 || (0x23...0x2B).contains($0) || (0x2D...0x3A).contains($0) ||
                          (0x3C...0x5B).contains($0) || (0x5D...0x7E).contains($0)
                      }) else { throw JarvisBootstrapError.invalidResponse }
            }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            let cookies = try result.cookies.map { c -> HTTPCookie in
                // Omit Domain in Set-Cookie to preserve host-only scope.
                let header = "\(c.name)=\(c.value); Path=/; Secure; HttpOnly; SameSite=Strict; Expires=\(formatter.string(from: Date(timeIntervalSince1970: Double(c.expires_at))))"
                let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: JarvisPolicy.home)
                guard parsed.count == 1, let cookie = parsed.first, cookie.domain == "jarvis.labbing.space",
                      cookie.path == "/", cookie.isSecure, cookie.isHTTPOnly, cookie.value == c.value,
                      cookie.sameSitePolicy?.rawValue.lowercased() == "strict",
                      cookie.expiresDate?.timeIntervalSince1970 == Double(c.expires_at) else { throw JarvisBootstrapError.invalidResponse }
                return cookie
            }
            let earliest = min(result.expires_at, result.cookies.map(\.expires_at).min()!)
            return Self(expiresAt: Date(timeIntervalSince1970: Double(earliest)), cookies: cookies)
        } catch { throw JarvisBootstrapError.invalidResponse }
    }
}

@MainActor
final class JarvisAppSessionBroker {
    typealias RequestBuilder = (String, Data) throws -> URLRequest
    private let build: RequestBuilder
    private let isAllowed: () -> Bool
    private let session: URLSession
    private let nonce: () throws -> String
    private let now: () -> Date
    private(set) var pending = false
    private(set) var lastCompensatingRevocationConfirmed: Bool?

    init(configuration: URLSessionConfiguration = .ephemeral, requestBuilder: @escaping RequestBuilder,
         isAllowed: @escaping () -> Bool, nonce: @escaping () throws -> String = JarvisSessionRequest.freshNonce,
         now: @escaping () -> Date = Date.init) {
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        build = requestBuilder; self.isAllowed = isAllowed; self.nonce = nonce; self.now = now
    }
    deinit { session.invalidateAndCancel() }
    func issue(installationID: UUID) async throws -> ValidatedJarvisAppSession {
        guard !pending else { throw JarvisBootstrapError.busy }
        guard isAllowed() else { throw JarvisBootstrapError.locked }
        pending = true; lastCompensatingRevocationConfirmed = nil; defer { pending = false }
        let request = JarvisSessionRequest(installationID: installationID, nonce: try nonce())
        do {
            let data = try await send(path: "/api/jarvis/app-session", request: request)
            return try ValidatedJarvisAppSession.decode(data, expectedNonce: request.nonce, now: now())
        } catch JarvisBootstrapError.invalidResponse {
            // This is a compensating revoke, never a second issuance attempt.
            do { try await performRevoke(installationID: installationID); lastCompensatingRevocationConfirmed = true }
            catch { lastCompensatingRevocationConfirmed = false }
            throw JarvisBootstrapError.invalidResponse
        }
    }
    func revoke(installationID: UUID) async throws {
        guard !pending else { throw JarvisBootstrapError.busy }
        pending = true; defer { pending = false }
        try await performRevoke(installationID: installationID)
    }
    private func performRevoke(installationID: UUID) async throws {
        let request = JarvisSessionRequest(installationID: installationID, nonce: try nonce())
        let data = try await send(path: "/api/jarvis/app-session/revoke", request: request)
        struct Ack: Decodable { let version: Int; let nonce: String; let revoked: Bool }
        guard let ack = try? JSONDecoder().decode(Ack.self, from: data), ack.version == 1,
              ack.nonce == request.nonce, ack.revoked else { throw JarvisBootstrapError.invalidResponse }
    }
    private func send(path: String, request: JarvisSessionRequest) async throws -> Data {
        guard isAllowed(), !Task.isCancelled else { throw JarvisBootstrapError.locked }
        try request.validate()
        var command = try build(path, JSONEncoder().encode(request))
        guard command.httpMethod == "POST", let url = command.url,
              url.scheme == "https", url.host == "control.admin-ai.site", (url.port == nil || url.port == 443),
              url.path == path, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              command.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true else { throw JarvisBootstrapError.invalidResponse }
        command.setValue(nil, forHTTPHeaderField: "Origin"); command.setValue(nil, forHTTPHeaderField: "Cookie")
        command.httpShouldHandleCookies = false
        command.setValue("application/json", forHTTPHeaderField: "Content-Type")
        command.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: command)
            guard isAllowed(), !Task.isCancelled else { throw JarvisBootstrapError.locked }
            guard let http = response as? HTTPURLResponse else { throw JarvisBootstrapError.invalidResponse }
            guard http.statusCode == 200 else { throw JarvisBootstrapError.http(http.statusCode) }
            guard data.count <= 65_536, http.mimeType == "application/json",
                  (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "no-store" }) else {
                throw JarvisBootstrapError.invalidResponse
            }
            return data
        } catch let safe as JarvisBootstrapError { throw safe }
        catch { throw JarvisBootstrapError.transport }
    }
}
