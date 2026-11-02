import XCTest
@testable import Orbit

@MainActor
final class PhonePilotTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let status = Data(#"{"version":1,"phone_seen_seconds":null,"health":{},"settings":{"revision":0,"mode":"web","forward_enabled":false},"settings_applied":false,"runtime":{"adb":"unknown","bluetooth":"unknown","battery":null,"workers":{}}}"#.utf8)
    override func setUp() async throws {
        suite = "PhonePilotTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
                         tokenProvider: { "phone-test-placeholder" }, authorize: authorize)
    }
    private func ready(_ api: ServerAPI) async throws {
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }
        await api.loadDashboard()
        let data = status
        MockURLProtocol.handler = { _ in (200, data) }
        _ = try await api.phonePilotStatus()
        MockURLProtocol.requests = []
    }
    private func command() -> OrbitPhonePilotCommand {
        OrbitPhonePilotCommand(request_id: UUID().uuidString.lowercased(), kind: "settings", revision: 0, mode: "web", forward_enabled: false)
    }
    func testInitialEmptyHealthAndPendingSettingsDecode() throws {
        let value = try JSONDecoder().decode(OrbitPhonePilotStatus.self, from: status)
        XCTAssertNil(value.health.at); XCTAssertNil(value.health.issues)
        XCTAssertNil(value.phone_seen_seconds); XCTAssertFalse(value.settings_applied)
    }
    func testStatusUsesOwnerBearerAndNoPairingKey() async throws {
        let api = api(); let data = status
        MockURLProtocol.handler = { _ in (200, data) }
        _ = try await api.phonePilotStatus()
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/jarvis-phone/status")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer phone-test-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertTrue(api.phonePilotStatusIsFresh)
    }
    func testUnavailableBackendAndWrongVersionNeverUnlock() async throws {
        let api = api(); let data = status
        MockURLProtocol.handler = { _ in (404, data) }
        do { _ = try await api.phonePilotStatus(); XCTFail() } catch { }
        XCTAssertFalse(api.phonePilotStatusIsFresh)
        MockURLProtocol.handler = { _ in (200, Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)) }
        do { _ = try await api.phonePilotStatus(); XCTFail() } catch { }
        XCTAssertFalse(api.phonePilotStatusIsFresh)
    }
    func testNoFreshStatusSendsNothingAndDoesNotAuthorize() async throws {
        var authorized = false
        let api = api(authorize: { _ in authorized = true })
        try await ready(api); api.invalidatePhonePilotStatus()
        do { _ = try await api.phonePilotSend(command()); XCTFail() } catch { }
        XCTAssertFalse(authorized); XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testAuthorizationCancellationSendsNothingAndReleasesBusy() async throws {
        let api = api(authorize: { _ in throw CancellationError() })
        try await ready(api)
        do { _ = try await api.phonePilotSend(command()); XCTFail() } catch { }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty); XCTAssertFalse(api.actionBusy)
    }
    func testLockDuringAuthorizationPreventsPostAndInvalidatesStatus() async throws {
        var instance: ServerAPI!
        instance = api(authorize: { _ in instance.setAccessAllowed(false) })
        try await ready(instance)
        do { _ = try await instance.phonePilotSend(command()); XCTFail() } catch { }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        XCTAssertFalse(instance.phonePilotStatusIsFresh); XCTAssertFalse(instance.actionBusy)
    }
    func testSinglePostAuthorizationBodyAndPendingAcknowledgement() async throws {
        var authorized = false
        let api = api(authorize: { _ in authorized = true })
        try await ready(api); let payload = command()
        MockURLProtocol.handler = { request in
            XCTAssertTrue(authorized)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/jarvis-phone/commands")
            return (200, Data("{\"request_id\":\"\(payload.request_id)\",\"status\":\"pending_phone\"}".utf8))
        }
        let result = try await api.phonePilotSend(payload)
        XCTAssertEqual(result.status, "pending_phone")
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertFalse(api.phonePilotStatusIsFresh); XCTAssertFalse(api.actionBusy)
    }
    func testTimeoutNeverRetriesOrFailsOver() async throws {
        let api = api(); try await ready(api)
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await api.phonePilotSend(command()); XCTFail() } catch { }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.host, "control.admin-ai.site")
        XCTAssertFalse(api.phonePilotStatusIsFresh); XCTAssertFalse(api.actionBusy)
        do { _ = try await api.phonePilotSend(command()); XCTFail() } catch { }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    func testStatusInFlightCannotRestoreFreshnessAfterInvalidation() async throws {
        let api = api(); let gate = DashboardRequestGate(); let data = status
        let started = expectation(description: "Status request started")
        MockURLProtocol.onStart = { gate.capture($0); started.fulfill() }
        let pending = Task { try await api.phonePilotStatus() }
        await fulfillment(of: [started], timeout: 3)
        api.invalidatePhonePilotStatus()
        gate.complete(with: data)
        do { _ = try await pending.value; XCTFail() } catch { }
        XCTAssertFalse(api.phonePilotStatusIsFresh)
    }
    func testInvalidCommandIsRejectedLocally() async throws {
        let api = api(); try await ready(api)
        let invalid = OrbitPhonePilotCommand(request_id: UUID().uuidString.lowercased(), kind: "automation", target: "shell", enabled: true)
        XCTAssertFalse(invalid.isValid)
        do { _ = try await api.phonePilotSend(invalid); XCTFail() } catch { }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
}
