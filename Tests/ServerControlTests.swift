import XCTest
import LocalAuthentication
import SwiftUI
import UIKit
@testable import ServerControl

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var requests: [URLRequest] = []
    static var onStart: ((MockURLProtocol) -> Void)?
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        let onStart = Self.onStart
        Self.lock.unlock()
        if let onStart { onStart(self); return }
        do {
            let (status, data) = try XCTUnwrap(handler)(request)
            respond(status: status, data: data)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DashboardRequestGate {
    private let lock = NSLock()
    private var pending: MockURLProtocol?
    func capture(_ request: MockURLProtocol) {
        lock.lock()
        pending = request
        lock.unlock()
    }
    func complete(with data: Data) {
        lock.lock()
        let request = pending
        pending = nil
        lock.unlock()
        request?.respond(status: 200, data: data)
    }
}

@MainActor
final class ServerControlTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        suite = "ServerControlTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []
        MockURLProtocol.onStart = nil
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil
        MockURLProtocol.onStart = nil
    }
    private func makeAPI(token: String = "unit-test-placeholder",
                         authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: configuration), defaults: defaults,
                         tokenProvider: { token }, authorize: authorize)
    }
    func testV1ContractAndCredentialBoundaries() async throws {
        let api = makeAPI()
        XCTAssertEqual(api.baseURL, "https://control.admin-ai.site")
        let request = try api.request(path: "/api/dashboard")
        XCTAssertEqual(request.url?.path, "/api/dashboard")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-placeholder")
        XCTAssertNil(try api.request(path: "/api/health", authenticated: false).value(forHTTPHeaderField: "Authorization"))
        await api.loadDashboard()
        XCTAssertEqual(api.dashboard?.processes.first?.id, 1)
        XCTAssertEqual(api.connection, .connected)
        XCTAssertTrue(api.canControl)
    }
    func testMissingTokenSendsNoRequest() async {
        let api = makeAPI(token: "")
        await api.loadDashboard()
        XCTAssertEqual(api.connection, .notConfigured)
        XCTAssertFalse(api.canControl)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testLogRouteLimitCacheAndCredentialBoundary() async throws {
        let api = makeAPI()
        let lines = (0..<700).map { LogLine(id: String($0), stream: $0.isMultiple(of: 2) ? "stdout" : "stderr", text: "Line \($0)", timestamp: nil) }
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(LogSnapshot(lines: lines, truncated: true, fetchedAt: "2026-10-03T00:00:00Z"))) }
        let result = try await api.loadLogs(.process(0))
        XCTAssertEqual(result.lines.count, 500)
        XCTAssertEqual(result.lines.first?.id, "200")
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/api/process/0/logs")
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.query, "limit=500")
        XCTAssertEqual(api.cachedLogs(.process(0))?.lines.count, 500)
        MockURLProtocol.handler = { _ in (501, Data()) }
        do { _ = try await api.loadLogs(.process(0)); XCTFail("Missing logs endpoint must fail") } catch { }
        XCTAssertEqual(api.cachedLogs(.process(0))?.lines.count, 500)
        api.setAccessAllowed(false)
        do { _ = try await api.loadLogs(.process(0)); XCTFail("Locked app must not request logs") } catch { }
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    private var visualServices: ServiceSnapshot {
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))
        let statuses = ["Working", "Rate Limited", "Invalid", "High Demand", "Google Issue", "Unknown"]
        return ServiceSnapshot(geminiHealth: "Working",
            gemini: (1...10).map { GeminiKeyStatus(id: "key-\($0)", name: "Gemini \($0)", status: statuses[($0-1) % statuses.count], lastAuthenticationCheck: now, lastGenerationCheck: now, canTest: $0 != 6) },
            classera: (1...3).map { ClasseraStatus(id: "classera-\($0)", name: "Classera \($0)", status: "Working", schedulerStatus: "Online", webhookStatus: "Working", lastRun: now, lastReport: now, lastReportName: nil, upcomingAssessments: nil, aiCache: nil, canFire: true, canForceFire: nil) },
            padel: ["watcher", "bot", "dashboard", "whatsapp"].map { PadelComponent(id: $0, name: "Padel \($0.capitalized)", status: "Online", deliveryStatus: "Billing Required", lastNotification: now) })
    }
    func testV4MajorScreensOnIPhone() async throws {
        let api = makeAPI()
        let services = visualServices
        let logData = LogSnapshot(lines: (1...16).map { LogLine(id: String($0), stream: $0.isMultiple(of: 4) ? "stderr" : "stdout", text: $0.isMultiple(of: 4) ? "Delivery billing check requires attention" : "Application health check completed", timestamp: nil) }, truncated: false, fetchedAt: ISO8601DateFormatter().string(from: Date()))
        MockURLProtocol.handler = { request in
            if request.url?.path.contains("/logs") == true {
                if request.url?.path.contains("/docker/") == true { return (501, Data()) }
                return (200, try JSONEncoder().encode(logData))
            }
            if request.url?.path == "/api/services" { return (200, try JSONEncoder().encode(services)) }
            return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
        }
        await api.refreshAll()
        api.library.toggle(.service(.padel))
        api.library.record(title: "Report request for Classera 1", result: .accepted)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousAppearance = UserDefaults.standard.string(forKey: "appearance.v2")
        defer {
            if let previousAppearance { UserDefaults.standard.set(previousAppearance, forKey: "appearance.v2") }
            else { UserDefaults.standard.removeObject(forKey: "appearance.v2") }
        }
        let screens: [(String, Int, DetailRoute?)] = [
            ("home", 0, nil), ("pm2", 1, nil), ("pm2-detail", 0, .process(1)),
            ("logs", 0, .logs(.process(1), "classera-service")), ("docker", 2, nil),
            ("docker-detail", 0, .docker("uptime-kuma")), ("gemini", 0, .service(.gemini)),
            ("classera", 0, .service(.classera)), ("padel", 0, .service(.padel)),
            ("activity", 3, nil), ("settings", 4, nil),
            ("docker-logs-unavailable", 0, .logs(.docker("uptime-kuma"), "uptime-kuma"))]
        for mode in ["light", "dark"] {
            for (screen, tab, destination) in screens {
                UserDefaults.standard.set(mode, forKey: "appearance.v2")
                let window = UIWindow(windowScene: scene)
                window.frame = scene.coordinateSpace.bounds
                window.rootViewController = UIHostingController(rootView: ContentView(api: api, initialTab: tab, initialDestination: destination))
                window.makeKeyAndVisible(); window.endEditing(true)
                let ready = expectation(description: "SwiftUI laid out \(screen) \(mode)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ready.fulfill() }
                await fulfillment(of: [ready], timeout: 5)
                window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "\(screen)-\(mode)"; attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertNil(api.errorMessage); window.isHidden = true
            }
        }
    }

    func testConnectivityFallbackPinsTrustedHostButAuthDoesNotFailOver() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { request in
            if request.url?.host == "control.admin-ai.site" { throw URLError(.cannotConnectToHost) }
            return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
        }
        await api.loadDashboard()
        XCTAssertEqual(MockURLProtocol.requests.map { $0.url!.host! }, ["control.admin-ai.site", "ubuntu-lts.tail341977.ts.net"])
        XCTAssertEqual(api.connection, .connected)
        await api.loadDashboard()
        XCTAssertEqual(MockURLProtocol.requests.last?.url?.host, "ubuntu-lts.tail341977.ts.net")
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
        let primary = makeAPI()
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in (401, Data()) }
        await primary.loadDashboard()
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(primary.connection, .unauthorized)
        XCTAssertNoThrow(try ServerAPI.validatedBaseURL("https://custom.example"))
        XCTAssertNoThrow(try ServerAPI.validatedBaseURL("https://custom.example:444"))
        XCTAssertNoThrow(try ServerAPI.validatedBaseURL("https://custom.example/server-control"))
    }

    func testBackgroundLocksRequestsAndControlsUntilFreshSnapshot() async {
        let api = makeAPI()
        await api.loadDashboard()
        let date = api.lastUpdated
        api.setAccessAllowed(false)
        MockURLProtocol.requests = []
        await api.loadDashboard()
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        XCTAssertFalse(api.canControl)
        XCTAssertEqual(api.lastUpdated, date)
        api.setAccessAllowed(true)
        XCTAssertFalse(api.canControl)
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await api.loadDashboard()
        XCTAssertNil(api.errorMessage)
        XCTAssertFalse(api.canControl)
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }
        await api.loadDashboard()
        XCTAssertTrue(api.canControl)
    }

    func testAppLockCancelKeepsLockedAndAllowsExplicitRetry() async {
        var attempts = 0
        let session = AppSession(defaults: defaults, authenticate: {
            attempts += 1
            if attempts == 1 { throw NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue) }
        })
        await session.activate()
        XCTAssertFalse(session.isUnlocked)
        await session.activate()
        XCTAssertEqual(attempts, 1)
        await session.unlock()
        XCTAssertTrue(session.isUnlocked)
        session.lock()
        XCTAssertFalse(session.isUnlocked)
        await session.activate()
        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(attempts, 3)
    }

    func testMissingServicesDoesNotInvalidateDashboard() async {
        let api = makeAPI()
        await api.loadDashboard()
        MockURLProtocol.handler = { _ in (501, Data()) }
        await api.loadServices()
        XCTAssertNotNil(api.servicesError)
        XCTAssertEqual(api.connection, .connected)
        XCTAssertNil(api.errorMessage)
        await api.serviceAction(ServiceCommand(kind: .fireClasseraReport, id: "classera-1", name: "Classera 1"))
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }


    func testExpandedClasseraResponseAndLegacyCompatibility() throws {
        let data = Data("""
        {"classera":[{"id":"classera-1","name":"Classera 1","status":"Working","lastReportName":"report.pdf","upcomingAssessments":[{"date":"2026-10-12","label":"FF","week":4,"subjects":["Math"]}],"aiCache":{"count":1,"recent":[{"hash":"cache-id","hasSummary":true}]},"canFire":true,"canForceFire":true}]}
        """.utf8)
        let service = try XCTUnwrap(JSONDecoder().decode(ServiceSnapshot.self, from: data).classera?.first)
        XCTAssertEqual(service.lastReportName, "report.pdf")
        XCTAssertEqual(service.upcomingAssessments?.first?.week, 4)
        XCTAssertEqual(service.aiCache?.recent?.first?.hasSummary, true)
        XCTAssertEqual(service.canForceFire, true)
        let legacy = try JSONDecoder().decode(ClasseraStatus.self, from: Data("""
        {"id":"classera-1","name":"Classera 1","status":"Working","canFire":true}
        """.utf8))
        XCTAssertNil(legacy.canForceFire)
        XCTAssertNil(legacy.aiCache)
    }

    func testForceSendRequiresBackendCapabilityAndAllowlistedID() async {
        let api = makeAPI()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/services" {
                return (200, Data("""
                {"classera":[{"id":"classera-1","name":"Classera 1","status":"Working","canFire":true},{"id":"unknown","name":"Unknown","status":"Working","canForceFire":true}]}
                """.utf8))
            }
            return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
        }
        await api.loadDashboard()
        await api.loadServices()
        for id in ["classera-1", "unknown"] {
            await api.serviceAction(ServiceCommand(kind: .forceFireClasseraReport, id: id, name: id))
        }
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }

    func testForceSendAuthorizationRouteAndNoRetry() async {
        for outcome in ["success", "cancel", "timeout"] {
            MockURLProtocol.requests = []
            var reasons: [String] = []
            let api = makeAPI(authorize: { reason in
                reasons.append(reason)
                if outcome == "cancel" { throw NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue) }
            })
            MockURLProtocol.handler = { request in
                if request.httpMethod == "POST" {
                    if outcome == "timeout" { throw URLError(.timedOut) }
                    return (200, Data("{\"ok\":true}".utf8))
                }
                if request.url?.path == "/api/services" {
                    return (200, Data("""
                    {"classera":[{"id":"classera-1","name":"Classera 1","status":"Working","canFire":false,"canForceFire":true}]}
                    """.utf8))
                }
                return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
            }
            await api.loadDashboard()
            await api.loadServices()
            await api.serviceAction(ServiceCommand(kind: .forceFireClasseraReport, id: "classera-1", name: "Classera 1"))
            XCTAssertEqual(reasons.count, 1)
            XCTAssertTrue(reasons.first?.contains("bypassing the delivery guard") == true)
            let posts = MockURLProtocol.requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(posts.count, outcome == "cancel" ? 0 : 1)
            if let post = posts.first { XCTAssertEqual(post.url?.path, "/api/services/classera/classera-1/force-fire") }
            if outcome == "timeout" { XCTAssertTrue(api.actionError?.contains("may have reached") == true) }
        }
    }

    func testClasseraRequiresAuthorizationAndUsesAllowlistedRoute() async throws {
        var authorizations = [String]()
        let api = makeAPI(authorize: { reason in authorizations.append(reason) })
        let services = Data("""
        {"classera":[{"id":"classera-1","name":"Classera 1","status":"Working","canFire":true}]}
        """.utf8)
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (200, Data("{\"ok\":true}".utf8)) }
            if request.url?.path == "/api/services" { return (200, services) }
            return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
        }
        await api.loadDashboard()
        await api.loadServices()
        await api.serviceAction(ServiceCommand(kind: .fireClasseraReport, id: "classera-1", name: "Classera 1"))
        XCTAssertEqual(authorizations.count, 1)
        XCTAssertTrue(authorizations.first?.contains("current Classera WhatsApp") == true)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.first?.url?.path, "/api/services/classera/classera-1/fire")
    }
    func testCancelledAuthorizationNeverPosts() async {
        let api = makeAPI(authorize: { _ in throw NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue) })
        await api.loadDashboard()
        await api.processAction(id: 1, name: "test-service", action: .restart)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
        XCTAssertEqual(api.actionNotice, "Cancelled. No command was sent.")
        XCTAssertFalse(api.actionBusy)
    }
    func testFailedAuthorizationNeverPosts() async {
        let api = makeAPI(authorize: { _ in throw APIError.message("Authentication unavailable") })
        await api.loadDashboard()
        await api.processAction(id: 1, name: "test-service", action: .stop)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertNotNil(api.actionError)
    }
    func testSuccessfulActionUsesExistingRouteThenRefreshes() async {
        var authorizationCount = 0
        let api = makeAPI(authorize: { _ in authorizationCount += 1 })
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (200, Data("{\"ok\":true}".utf8)) }
            return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
        }
        await api.loadDashboard()
        await api.processAction(id: 1, name: "test-service", action: .restart)
        XCTAssertEqual(authorizationCount, 1)
        XCTAssertEqual(MockURLProtocol.requests.map { $0.httpMethod ?? "" }, ["GET", "POST", "GET"])
        XCTAssertEqual(MockURLProtocol.requests[1].url?.path, "/api/process/1/restart")
        XCTAssertNil(api.actionError)
    }
    func testStaleSnapshotDisablesCommands() async {
        let api = makeAPI()
        await api.loadDashboard()
        let date = api.lastUpdated
        MockURLProtocol.handler = { _ in (401, Data()) }
        await api.loadDashboard()
        XCTAssertNotNil(api.dashboard)
        XCTAssertEqual(api.lastUpdated, date)
        XCTAssertEqual(api.connection, .unauthorized)
        XCTAssertFalse(api.canControl)
        await api.processAction(id: 1, name: "test-service", action: .stop)
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }
    func testCommandTimeoutNeverRetries() async {
        let api = makeAPI()
        await api.loadDashboard()
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await api.processAction(id: 1, name: "test-service", action: .restart)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(api.connection, .unreachable)
        XCTAssertTrue(api.actionError?.contains("may have reached") ?? false)
    }

    func testCancelledCommandRequiresVerificationWithoutFalseOutageOrRetry() async {
        let api = makeAPI()
        await api.loadDashboard()
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await api.processAction(id: 1, name: "test-service", action: .restart)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(api.connection, .connected)
        XCTAssertNil(api.errorMessage)
        XCTAssertFalse(api.canControl)
        XCTAssertTrue(api.actionError?.contains("may have reached") == true)
    }

    func testCancelledClasseraAuthorizationDoesNotFire() async throws {
        let api = makeAPI(authorize: { _ in throw NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue) })
        let services = Data("""
        {"classera":[{"id":"classera-1","name":"Classera 1","status":"Working","canFire":true}]}
        """.utf8)
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/services" { return (200, services) }
            return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
        }
        await api.loadDashboard()
        await api.loadServices()
        await api.serviceAction(ServiceCommand(kind: .fireClasseraReport, id: "classera-1", name: "Classera 1"))
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
        XCTAssertEqual(api.actionNotice, "Cancelled. No command was sent.")
    }
    func testSecureURLValidationAndPathEncoding() throws {
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com?token=x", "https://example.com#fragment"] {
            XCTAssertThrowsError(try ServerAPI.validatedBaseURL(url))
        }
        XCTAssertNoThrow(try ServerAPI.validatedBaseURL(ServerAPI.defaultBaseURL))
        XCTAssertEqual(try ServerAPI.encodedContainerName("name/with?query"), "name%2Fwith%3Fquery")
        XCTAssertThrowsError(try ServerAPI.encodedContainerName(""))
    }
    func testRedirectDelegateRejectsCredentialForwarding() {
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let task = URLSession.shared.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var callbackCalled = false
        NoRedirectDelegate().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: request) { next in
            callbackCalled = true
            XCTAssertNil(next)
        }
        XCTAssertTrue(callbackCalled)
        task.cancel()
    }
    func testNotificationFoundationHasNoActiveRemoteTransport() {
        XCTAssertFalse(DeferredAlertTransport().isAvailable)
        XCTAssertEqual(AlertCategory.allCases.count, 8)
    }

    func testCancelledRefreshPreservesSuccessfulSnapshotAndConnection() async {
        let api = makeAPI()
        await api.loadDashboard()
        let date = api.lastUpdated
        let name = api.dashboard?.processes.first?.name
        XCTAssertTrue(ServerAPI.isRefreshCancellation(CancellationError()))
        let cancellations: [Error] = [URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)]
        for cancellation in cancellations {
            MockURLProtocol.handler = { _ in throw cancellation }
            await api.loadDashboard()
            XCTAssertEqual(api.connection, .connected)
            XCTAssertEqual(api.lastUpdated, date)
            XCTAssertEqual(api.dashboard?.processes.first?.name, name)
            XCTAssertNil(api.errorMessage)
            XCTAssertFalse(api.loading)
            XCTAssertTrue(api.canControl)
        }
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }
        await api.loadDashboard()
        XCTAssertEqual(api.connection, .connected)
        XCTAssertNil(api.errorMessage)
    }

    func testCancelledInitialRefreshDoesNotReportConnectionLost() async {
        let api = makeAPI()
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await api.loadDashboard()
        XCTAssertEqual(api.connection, .notConfigured)
        XCTAssertNil(api.errorMessage)
        XCTAssertNil(api.dashboard)
        XCTAssertFalse(api.loading)
    }

    func testCancellationPreservesAnExistingGenuineOutage() async {
        let api = makeAPI()
        await api.loadDashboard()
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await api.loadDashboard()
        let error = api.errorMessage
        let date = api.lastUpdated
        XCTAssertEqual(api.connection, .unreachable)
        XCTAssertNotNil(api.dashboard)
        XCTAssertNotNil(error)
        XCTAssertFalse(api.canControl)
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await api.loadDashboard()
        XCTAssertEqual(api.connection, .unreachable)
        XCTAssertEqual(api.errorMessage, error)
        XCTAssertEqual(api.lastUpdated, date)
    }

    func testTabAndPullToRefreshWaitersShareRequestDespiteCancellation() async throws {
        let api = makeAPI()
        await api.loadDashboard()
        MockURLProtocol.requests = []
        let started = expectation(description: "Shared request started")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        var firstReturned = false
        var secondReturned = false
        let first = Task { await api.loadDashboard(); firstReturned = true }
        await fulfillment(of: [started], timeout: 5)
        first.cancel() // SwiftUI removes the view that originally requested refresh.
        let joined = expectation(description: "Pull-to-refresh joined")
        let second = Task { joined.fulfill(); await api.loadDashboard(); secondReturned = true }
        await fulfillment(of: [joined], timeout: 5)
        second.cancel() // Another tab disappears while the shared request is pending.
        XCTAssertFalse(firstReturned)
        XCTAssertFalse(secondReturned)
        XCTAssertTrue(api.loading)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(api.connection, .connected)
        XCTAssertNil(api.errorMessage)
        gate.complete(with: try JSONEncoder().encode(PreviewFixtures.dashboard))
        await first.value
        await second.value
        XCTAssertTrue(firstReturned)
        XCTAssertTrue(secondReturned)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertFalse(api.loading)
        XCTAssertEqual(api.connection, .connected)
        XCTAssertNil(api.errorMessage)
        XCTAssertTrue(api.canControl)
        MockURLProtocol.onStart = nil
        await api.loadDashboard()
        XCTAssertEqual(MockURLProtocol.requests.count, 2) // Next pull starts immediately.
    }

    func testAlreadyCancelledCallerDoesNotStartRefresh() async {
        let api = makeAPI()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await api.loadDashboard()
        }
        await caller.value
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        XCTAssertEqual(api.connection, .notConfigured)
        XCTAssertNil(api.errorMessage)
        XCTAssertFalse(api.loading)
    }
    func testServiceDecodingAndEveryGeminiStatus() throws {
        let decoded = try JSONDecoder().decode(ServiceSnapshot.self, from: JSONEncoder().encode(visualServices))
        XCTAssertEqual(decoded.gemini?.count, 10)
        for state in ["Working", "Rate Limited", "Invalid", "High Demand", "Google Issue", "Unknown"] {
            XCTAssertTrue(decoded.gemini?.contains { $0.status == state } == true)
        }
        XCTAssertEqual(StatusTone("Working"), .healthy)
        XCTAssertEqual(StatusTone("Rate Limited"), .warning)
        XCTAssertEqual(StatusTone("Invalid"), .error)
        XCTAssertEqual(StatusTone("High Demand"), .warning)
        XCTAssertEqual(StatusTone("Google Issue"), .error)
        XCTAssertEqual(StatusTone("Unknown"), .unknown)
    }
    func testClasseraAndPadelStatesStayIndependent() async throws {
        let api = makeAPI()
        let services = visualServices
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(services)) }
        await api.loadServices()
        XCTAssertEqual(api.serviceSnapshot?.classera?.count, 3)
        XCTAssertEqual(api.serviceSnapshot?.classera?.first?.schedulerStatus, "Online")
        XCTAssertEqual(api.serviceSnapshot?.classera?.first?.webhookStatus, "Working")
        XCTAssertEqual(api.serviceStatus(.padel), "Billing Required")
        XCTAssertTrue(api.serviceSnapshot?.padel?.allSatisfy { $0.status == "Online" } == true)
        for delivery in ["Billing Required", "Payment Ineligible", "Delivery Failed", "Working", "Unknown"] {
            let component = PadelComponent(id: "whatsapp", name: "WhatsApp", status: "Online", deliveryStatus: delivery, lastNotification: nil)
            let decoded = try JSONDecoder().decode(PadelComponent.self, from: JSONEncoder().encode(component))
            XCTAssertEqual(decoded.deliveryStatus, delivery)
            XCTAssertEqual(decoded.status, "Online")
        }
    }
    func testHumanReadableDatesAndInvalidDates() throws {
        let now = try XCTUnwrap(HumanTime.parse("2026-10-03T12:00:00Z"))
        XCTAssertEqual(HumanTime.label("2026-10-03T11:59:40Z", now: now), "Just now")
        XCTAssertEqual(HumanTime.label("2026-10-03T11:56:00.000000+00:00", now: now), "4 min ago")
        XCTAssertTrue(HumanTime.label("2026-10-03T08:00:00Z", now: now).hasPrefix("Today,"))
        XCTAssertEqual(HumanTime.label("2026-10-02T12:00:00Z", now: now), "Yesterday")
        XCTAssertEqual(HumanTime.label("invalid", now: now), "Not reported")
        XCTAssertEqual(HumanTime.label(nil, now: now), "Not reported")
    }
    func testFavoritesAndBoundedLocalHistoryPersist() {
        let library = HomelabStore(defaults: defaults)
        library.toggle(.service(.padel)); library.toggle(.process(2)); library.toggle(.docker("immich-server"))
        for i in 0..<110 { library.record(title: "Restart process \(i)", result: .accepted) }
        let loaded = HomelabStore(defaults: defaults)
        XCTAssertEqual(loaded.favorites.count, 3)
        XCTAssertEqual(loaded.events.count, 100)
        XCTAssertEqual(loaded.events.first?.title, "Restart process 109")
        loaded.toggle(.process(2)); XCTAssertFalse(loaded.favorites.contains(.process(2)))
        loaded.clearHistory(); XCTAssertTrue(HomelabStore(defaults: defaults).events.isEmpty)
    }
    func testCustomHTTPSDoesNotFailOverToAnotherServer() async throws {
        defaults.set("https://custom.example:8443/control", forKey: "serverURL")
        let api = makeAPI()
        XCTAssertEqual(try api.request(path: "/api/dashboard").url?.absoluteString, "https://custom.example:8443/control/api/dashboard")
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        await api.loadDashboard()
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.host, "custom.example")
    }
    func testConcurrentCommandsAuthorizeAndPostOnlyOnce() async throws {
        let started = expectation(description: "Authentication started")
        var resume: CheckedContinuation<Void, Never>?
        let api = makeAPI(authorize: { _ in await withCheckedContinuation { resume = $0; started.fulfill() } })
        await api.loadDashboard()
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (200, Data("{\"ok\":true}".utf8)) }
            return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
        }
        let first = Task { await api.processAction(id: 1, name: "classera-service", action: .restart) }
        await fulfillment(of: [started], timeout: 5)
        await api.processAction(id: 1, name: "classera-service", action: .restart)
        resume?.resume(); await first.value
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(api.library.events.count, 1)
        XCTAssertEqual(api.library.events.first?.result, .accepted)
        await api.processAction(id: 999, name: "unknown", action: .stop)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testOptionalAppLockNeverDisablesSensitiveActionAuthentication() async {
        defaults.set(false, forKey: "appLock.v4")
        var unlockCalls = 0
        let session = AppSession(defaults: defaults, authenticate: { unlockCalls += 1 })
        await session.activate(); XCTAssertTrue(session.isUnlocked); XCTAssertEqual(unlockCalls, 0)
        var actionCalls = 0
        let api = makeAPI(authorize: { _ in actionCalls += 1; throw NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue) })
        await api.loadDashboard(); await api.processAction(id: 1, name: "classera-service", action: .stop)
        XCTAssertEqual(actionCalls, 1); XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
        XCTAssertEqual(api.library.events.first?.result, .cancelled)
    }
    func testLogClientRedactionAndStreamBoundary() async throws {
        let api = makeAPI()
        let raw = LogSnapshot(lines: [LogLine(id: "1", stream: "stderr", text: "Authorization: Bearer test-secret-sentinel", timestamp: nil), LogLine(id: "2", stream: "stdout", text: "password=sentinel token=sentinel", timestamp: nil), LogLine(id: "3", stream: "other", text: "hidden", timestamp: nil)], truncated: false, fetchedAt: nil)
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(raw)) }
        let logs = try await api.loadLogs(.process(1))
        XCTAssertEqual(logs.lines.count, 2)
        XCTAssertFalse(logs.lines.map(\.text).joined().contains("sentinel"))
        XCTAssertTrue(logs.lines.map(\.text).joined().contains("[redacted]"))
    }

}
