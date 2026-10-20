import Foundation
import WebKit
import Combine

@MainActor protocol JarvisSessionServing: AnyObject {
    func issue(installationID: UUID) async throws -> ValidatedJarvisAppSession
    func revoke(installationID: UUID) async throws
}
extension JarvisAppSessionBroker: JarvisSessionServing {}

@MainActor protocol JarvisCookieStoring: AnyObject {
    func all() async -> [HTTPCookie]
    func set(_ cookie: HTTPCookie) async
    func delete(_ cookie: HTTPCookie) async
}

@MainActor final class JarvisWebKitCookies: JarvisCookieStoring {
    private let store: WKHTTPCookieStore
    init(_ store: WKHTTPCookieStore) { self.store = store }
    func all() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in store.getAllCookies { continuation.resume(returning: $0) } }
    }
    func set(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in store.setCookie(cookie) { continuation.resume() } }
    }
    func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in store.delete(cookie) { continuation.resume() } }
    }
}

/// Serializes the native handoff and cookie installation. Never evaluates JS or starts capture.
@MainActor final class JarvisAppConnection: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var supportsMemory = false
    @Published private(set) var message: String?
    private let makeBroker: () throws -> JarvisSessionServing
    private let installation: () throws -> UUID
    private let allowed: () -> Bool
    private let cookies: JarvisCookieStoring
    private let now: () -> Date
    private let stop: () -> Void
    private let navigate: (URL) -> Void
    private var generation = 0
    private var expiryTask: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var broker: JarvisSessionServing?
    private var device: UUID?
    private(set) var expiresAt: Date?

    init(cookies: JarvisCookieStoring, makeBroker: @escaping () throws -> JarvisSessionServing,
         installation: @escaping () throws -> UUID, allowed: @escaping () -> Bool,
         now: @escaping () -> Date = Date.init, stop: @escaping () -> Void,
         navigate: @escaping (URL) -> Void) {
        self.cookies = cookies; self.makeBroker = makeBroker; self.installation = installation
        self.allowed = allowed; self.now = now; self.stop = stop; self.navigate = navigate
    }

    deinit { expiryTask?.cancel() }

    func connect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await cleanup?.value; cleanup = nil
        guard allowed(), !Task.isCancelled else { message = JarvisBootstrapError.locked.localizedDescription; return }
        generation += 1; let attempt = generation
        stop(); connected = false; supportsMemory = false; expiresAt = nil; expiryTask?.cancel()
        message = "Establishing a private JARVIS session…"
        var issued = false
        var activeBroker: JarvisSessionServing?
        var installationID: UUID?
        do {
            let client = try makeBroker(), id = try installation()
            activeBroker = client; installationID = id
            let result = try await client.issue(installationID: id); issued = true
            try check(attempt, expiry: result.expiresAt)
            await clearCookies()
            for cookie in result.cookies {
                try check(attempt, expiry: result.expiresAt)
                await cookies.set(cookie)
            }
            try check(attempt, expiry: result.expiresAt)
            let installed = await cookies.all()
            try check(attempt, expiry: result.expiresAt)
            guard Self.matches(result.cookies, installed) else { throw JarvisBootstrapError.invalidResponse }
            broker = client; device = id; expiresAt = result.expiresAt
            connected = true; supportsMemory = result.memoryAvailable
            message = result.memoryAvailable ? nil : "Connected. Memory is unavailable on the current JARVIS server."
            navigate(result.entryURL)
            let delay = max(0, result.expiresAt.timeIntervalSince(now()))
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.generation == attempt else { return }
                await self.expire()
            }
        } catch {
            await clearCookies()
            // A completed issuance can need compensation after cancellation or read-back failure.
            // No issuance retry and no POST replay on uncertain transport failures.
            if issued, allowed(), let activeBroker, let installationID {
                try? await activeBroker.revoke(installationID: installationID)
            }
            if generation == attempt {
                connected = false
                message = (error as? JarvisBootstrapError)?.localizedDescription ?? "JARVIS session could not be installed. Reconnect when ready."
            }
        }
    }

    func signOut() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        generation += 1; expiryTask?.cancel(); stop(); connected = false; supportsMemory = false; expiresAt = nil
        await cleanup?.value; cleanup = nil
        let client = broker; let id = device; broker = nil; device = nil
        var revoked = false
        if let client, let id, allowed() {
            do { try await client.revoke(installationID: id); revoked = true } catch {}
        }
        await clearCookies()
        message = revoked ? "Signed out. This device’s JARVIS session was revoked." : "Signed out locally. Server revocation could not be confirmed; the short-lived session will expire."
    }

    /// Background/lock/navigation invalidate every pending install before any await.
    func suspend() {
        generation += 1; expiryTask?.cancel(); connected = false; supportsMemory = false; expiresAt = nil; stop()
        message = "JARVIS paused. Unlock Orbit, then Reconnect."
        let previous = cleanup
        cleanup = Task { [weak self] in
            await previous?.value
            await self?.clearCookies()
        }
    }

    func rejectedPage() { suspend(); message = "JARVIS authentication or page loading failed. No login bypass was attempted. Reconnect when ready." }

    func expire() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        generation += 1; expiryTask?.cancel(); connected = false; supportsMemory = false; expiresAt = nil; stop()
        await clearCookies()
        message = "JARVIS session expired. Reconnect to continue; voice will stay stopped."
    }

    private func check(_ attempt: Int, expiry: Date) throws {
        guard generation == attempt, allowed(), !Task.isCancelled else { throw JarvisBootstrapError.locked }
        guard expiry.timeIntervalSince(now()) > 0 else { throw JarvisBootstrapError.invalidResponse }
    }
    private func clearCookies() async {
        for cookie in await cookies.all() where Self.scoped(cookie) { await cookies.delete(cookie) }
    }
    static func scoped(_ cookie: HTTPCookie) -> Bool {
        ["jarvis", "CF_Authorization", "CF_Binding", "CF_AppSession"].contains(cookie.name) &&
            ["jarvis.labbing.space", ".jarvis.labbing.space"].contains(cookie.domain.lowercased())
    }
    static func matches(_ expected: [HTTPCookie], _ actual: [HTTPCookie]) -> Bool {
        let scoped = actual.filter(Self.scoped)
        guard scoped.count == expected.count else { return false }
        return expected.allSatisfy { target in
            scoped.contains { cookie in
                cookie.name == target.name && cookie.value == target.value && cookie.domain == target.domain &&
                cookie.path == "/" && cookie.isSecure && cookie.isHTTPOnly &&
                cookie.sameSitePolicy == .sameSiteStrict && cookie.expiresDate == target.expiresDate
            }
        }
    }
}
