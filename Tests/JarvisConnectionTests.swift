import XCTest
import WebKit
@testable import Orbit

@MainActor private final class TestJarvisCookies: JarvisCookieStoring {
    var values: [HTTPCookie] = []
    var dropWrites = false
    var onSet: (() -> Void)?
    func all() async -> [HTTPCookie] { values }
    func set(_ cookie: HTTPCookie) async { if !dropWrites { values.append(cookie) }; onSet?() }
    func delete(_ cookie: HTTPCookie) async { values.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path } }
}
@MainActor private final class TestJarvisBroker: JarvisSessionServing {
    let result: ValidatedJarvisAppSession
    var issues = 0, revokes = 0
    var failRevoke = false
    var wait = false
    var onIssue: (() -> Void)?
    var continuation: CheckedContinuation<ValidatedJarvisAppSession, Error>?
    init(_ result: ValidatedJarvisAppSession) { self.result = result }
    func issue(installationID: UUID) async throws -> ValidatedJarvisAppSession {
        issues += 1
        if wait { return try await withCheckedThrowingContinuation { continuation = $0; onIssue?() } }
        return result
    }
    func revoke(installationID: UUID) async throws {
        revokes += 1; if failRevoke { throw JarvisBootstrapError.transport }
    }
}

@MainActor final class JarvisConnectionTests: XCTestCase {
    private func result() throws -> ValidatedJarvisAppSession {
        let now = Int(Date().timeIntervalSince1970), nonce = String(repeating: "a", count: 43)
        let cookies = ["jarvis", "CF_Authorization"].map { name -> [String: Any] in
            ["name": name, "value": "synthetic-only", "domain": "jarvis.labbing.space", "path": "/",
             "secure": true, "http_only": true, "same_site": "Strict", "expires_at": now + 600]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "nonce": nonce,
            "entry_url": "https://jarvis.labbing.space/", "expires_at": now + 600, "cookies": cookies])
        return try ValidatedJarvisAppSession.decode(data, expectedNonce: nonce, now: Date(timeIntervalSince1970: Double(now)))
    }
    private func connection(_ jar: TestJarvisCookies, _ broker: TestJarvisBroker,
                            allowed: @escaping () -> Bool = { true },
                            stop: @escaping () -> Void = {}, navigate: @escaping (URL) -> Void = { _ in }) -> JarvisAppConnection {
        JarvisAppConnection(cookies: jar, makeBroker: { broker }, installation: { UUID() }, allowed: allowed, stop: stop, navigate: navigate)
    }
    func testInstallsAllCookiesBeforeNavigationAndDoesNotStartMicrophone() async throws {
        let jar = TestJarvisCookies(), broker = TestJarvisBroker(try result())
        var destinations: [URL] = [], stops = 0
        let c = connection(jar, broker, stop: { stops += 1 }, navigate: { url in
            XCTAssertEqual(jar.values.count, 2); destinations.append(url)
        })
        await c.connect()
        XCTAssertTrue(c.connected); XCTAssertEqual(destinations, [JarvisPolicy.home]); XCTAssertEqual(stops, 1)
        XCTAssertEqual(broker.issues, 1); XCTAssertEqual(broker.revokes, 0)
        c.suspend()
    }
    func testLockedAppNeverIssues() async throws {
        let jar = TestJarvisCookies(), broker = TestJarvisBroker(try result())
        let c = connection(jar, broker, allowed: { false })
        await c.connect(); XCTAssertEqual(broker.issues, 0); XCTAssertTrue(jar.values.isEmpty); XCTAssertFalse(c.connected)
    }
    func testReadBackFailureRollsBackAndRevokesWithoutReissuing() async throws {
        let jar = TestJarvisCookies(), broker = TestJarvisBroker(try result()); jar.dropWrites = true
        var navigated = false
        let c = connection(jar, broker, navigate: { _ in navigated = true })
        await c.connect()
        XCTAssertFalse(navigated); XCTAssertFalse(c.connected); XCTAssertTrue(jar.values.isEmpty)
        XCTAssertEqual(broker.issues, 1); XCTAssertEqual(broker.revokes, 1)
    }
    func testBackgroundDuringInstallationRollsBackBeforeNavigation() async throws {
        let jar = TestJarvisCookies(), broker = TestJarvisBroker(try result())
        var navigated = false, active = true
        let c = connection(jar, broker, allowed: { active }, navigate: { _ in navigated = true })
        jar.onSet = { active = false; c.suspend() }
        await c.connect()
        XCTAssertFalse(navigated); XCTAssertFalse(c.connected); XCTAssertTrue(jar.values.isEmpty)
        XCTAssertEqual(broker.issues, 1)
    }
    func testOldReplyAndDuplicateRequestsCannotRestoreAccessAfterLock() async throws {
        let jar = TestJarvisCookies(), broker = TestJarvisBroker(try result()); broker.wait = true
        let entered = expectation(description: "Issuance started"); broker.onIssue = { entered.fulfill() }
        var active = true, navigated = false
        let c = connection(jar, broker, allowed: { active }, navigate: { _ in navigated = true })
        let task = Task { await c.connect() }
        await fulfillment(of: [entered], timeout: 2)
        await c.connect(); await c.signOut(); XCTAssertEqual(broker.issues, 1); XCTAssertEqual(broker.revokes, 0)
        active = false; c.suspend(); broker.continuation?.resume(returning: broker.result)
        await task.value
        XCTAssertFalse(navigated); XCTAssertTrue(jar.values.isEmpty); XCTAssertFalse(c.connected)
    }
    func testSignOutReportsOfflineRevocationAndPreservesUnrelatedCookies() async throws {
        let jar = TestJarvisCookies(), broker = TestJarvisBroker(try result()); broker.failRevoke = true
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [.name: "jarvis", .value: "unrelated", .domain: "other.example", .path: "/"]))
        jar.values = [unrelated]
        let c = connection(jar, broker)
        await c.connect(); await c.signOut()
        XCTAssertEqual(jar.values.count, 1); XCTAssertEqual(jar.values.first?.domain, "other.example")
        XCTAssertTrue(c.message?.contains("could not be confirmed") == true)
        XCTAssertEqual(broker.revokes, 1); XCTAssertEqual(broker.issues, 1)
    }
    func testExpiryStopsAndClearsWithoutAutomaticRenewal() async throws {
        let jar = TestJarvisCookies(), broker = TestJarvisBroker(try result()); var stops = 0
        let c = connection(jar, broker, stop: { stops += 1 })
        await c.connect(); await c.expire()
        XCTAssertFalse(c.connected); XCTAssertTrue(jar.values.isEmpty); XCTAssertEqual(broker.issues, 1)
        XCTAssertEqual(stops, 2); XCTAssertTrue(c.message?.contains("expired") == true)
    }
    func testActualWebKitCookieStorePreservesValidatedScopeAndSecurity() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let jar = JarvisWebKitCookies(dataStore.httpCookieStore)
        let broker = TestJarvisBroker(try result())
        var navigated = false
        let c = JarvisAppConnection(cookies: jar, makeBroker: { broker }, installation: { UUID() },
            allowed: { true }, stop: {}, navigate: { _ in navigated = true })
        await c.connect()
        XCTAssertTrue(c.connected); XCTAssertTrue(navigated)
        let installed = await jar.all()
        XCTAssertTrue(JarvisAppConnection.matches(broker.result.cookies, installed))
        XCTAssertFalse(c.supportsMemory, "Missing capability is not confirmed Memory support")
        await c.signOut()
        let remaining = await jar.all()
        XCTAssertFalse(remaining.contains(where: JarvisAppConnection.scoped))
        XCTAssertEqual(broker.revokes, 1)
    }
}
