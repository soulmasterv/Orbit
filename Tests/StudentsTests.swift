import XCTest
@testable import ServerControl

@MainActor
final class StudentsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let connection = StudentsConnection(baseURL: "https://students.example", apiKey: "unit-test-placeholder")
    private let payload = Data(#"[{"phone":"201000000002","name":"Ahmed Ali","grade":"10","state":"active","first_seen":1760438400,"last_inbound_at":1760442000,"window_open":true,"seconds_left":5400},{"phone":"201000000001","name":null,"grade":null,"state":"awaiting_name","window_open":false,"seconds_left":0}]"#.utf8)

    override func setUp() async throws {
        suite = "StudentsTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []
        MockURLProtocol.onStart = nil
        let data = payload
        MockURLProtocol.handler = { _ in (200, data) }
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil
        MockURLProtocol.onStart = nil
    }
    private func makeAPI() -> ServerAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: configuration), defaults: defaults,
                         tokenProvider: { "bearer-must-not-be-sent" }, authorize: { _ in })
    }

    func testDecodingOrderNullOnboardingAndUnixTimestamps() throws {
        let students = try JSONDecoder().decode([Student].self, from: payload)
        XCTAssertEqual(students.map(\.phone), ["201000000002", "201000000001"])
        XCTAssertEqual(students[0].firstSeenDate, Date(timeIntervalSince1970: 1760438400))
        XCTAssertEqual(students[0].lastInboundDate, Date(timeIntervalSince1970: 1760442000))
        XCTAssertEqual(students[1].displayName, "Not provided yet")
        XCTAssertEqual(students[1].displayGrade, "Not provided yet")
        XCTAssertEqual(students[1].stateLabel, "Awaiting Name")
        XCTAssertNil(students[1].firstSeenDate)
        XCTAssertNil(students[1].lastInboundDate)
        XCTAssertTrue(students[0].maskedPhone.hasSuffix("0002"))
        XCTAssertFalse(students[0].maskedPhone.contains("20100000"))
    }

    func testCountdownUsesElapsedTimeExpiresAndResyncsWithoutRequests() throws {
        let students = try JSONDecoder().decode([Student].self, from: payload)
        let start = ContinuousClock.now
        // Calendar time is only metadata; it does not control the window.
        let first = StudentsSnapshot(students: students, receivedAt: .distantFuture, receivedInstant: start)
        XCTAssertEqual(first.countdown(for: students[0], at: start), "01:30")
        XCTAssertEqual(first.countdown(for: students[0], at: start.advanced(by: .seconds(60))), "01:29")
        XCTAssertFalse(first.isWindowOpen(for: students[0], at: start.advanced(by: .seconds(5400))))
        XCTAssertEqual(first.countdown(for: students[0], at: start.advanced(by: .seconds(9000))), "00:00")
        XCTAssertFalse(first.isWindowOpen(for: students[1], at: start))
        let refreshed = StudentsSnapshot(students: students, receivedAt: .distantPast, receivedInstant: start.advanced(by: .seconds(5400)))
        XCTAssertEqual(refreshed.countdown(for: students[0], at: start.advanced(by: .seconds(5400))), "01:30")
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testStudentsGETUsesOnlyDedicatedAPIKeyAndConfiguredURL() async throws {
        let api = makeAPI()
        let result = try await api.fetchStudents(connection: connection)
        XCTAssertEqual(result.students.count, 2)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://students.example/api/students")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "unit-test-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testUnauthorizedAndNetworkErrorsAreClearWithoutFailover() async {
        let api = makeAPI()
        let store = StudentsStore(api: api, connectionProvider: { self.connection })
        await store.refresh()
        XCTAssertEqual(store.snapshot?.students.count, 2)
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in (401, Data()) }
        await store.refresh()
        XCTAssertTrue(store.error?.contains("API key was rejected (401)") == true)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await store.refresh()
        XCTAssertTrue(store.error?.contains("took too long") == true)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testRefreshCoalescesAndLockedScreenDoesNotRequest() async {
        let api = makeAPI()
        let store = StudentsStore(api: api, connectionProvider: { self.connection })
        let gate = DashboardRequestGate()
        let started = expectation(description: "Students request started")
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        let first = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let joined = expectation(description: "Second refresh joined")
        let second = Task { joined.fulfill(); await store.refresh() }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        gate.complete(with: payload)
        await first.value
        await second.value
        XCTAssertNotNil(store.snapshot)
        store.suspend(clear: true)
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.loading)

        MockURLProtocol.onStart = nil
        api.setAccessAllowed(false)
        MockURLProtocol.requests = []
        await store.refresh()
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testMissingConfigurationAndUnsafeConnectionAreRejected() async {
        let store = StudentsStore(api: makeAPI(), connectionProvider: { nil })
        await store.refresh()
        XCTAssertTrue(store.error?.contains("Settings") == true)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        for url in ["", "http://students.example", "https://user:password@students.example", "https://students.example?key=example"] {
            XCTAssertThrowsError(try StudentsConnection(baseURL: url, apiKey: "unit-test-placeholder").validated())
        }
        for key in ["", " ", "bad\nkey"] {
            XCTAssertThrowsError(try StudentsConnection(baseURL: "https://students.example", apiKey: key).validated())
        }
    }
}
