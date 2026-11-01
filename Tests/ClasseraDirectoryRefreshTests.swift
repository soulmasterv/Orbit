import XCTest
@testable import Orbit

@MainActor
final class ClasseraDirectoryRefreshTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        suite = "ClasseraDirectoryRefreshTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api() -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
                         tokenProvider: { "owner-placeholder" }, authorize: { _ in })
    }
    private func response(_ phone: String = "201000000001") -> Data {
        Data("""
        {"version":1,"students":[{"phone":"\(phone)","profile_name":"Student","activity_status":"allowed",
        "revision":"\(String(repeating: "a", count: 64))","subscriptions":[],"signup_session":null}]}
        """.utf8)
    }
    func testCancellingPullWaiterDoesNotDiscardOwnedRefreshOrShowError() async {
        let store = ClasseraDirectoryStore(); let api = api(); let data = response()
        let started = expectation(description: "read started")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        let waiter = Task { await store.refresh(api: api) }
        await fulfillment(of: [started], timeout: 2)
        waiter.cancel(); gate.complete(with: data); await waiter.value
        XCTAssertEqual(store.students.first?.phone, "201000000001")
        XCTAssertNil(store.error); XCTAssertFalse(store.loading)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    func testConcurrentPullAndAppearanceCoalesceOneRead() async {
        let store = ClasseraDirectoryStore(); let api = api(); let data = response()
        let started = expectation(description: "read started")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        let first = Task { await store.refresh(api: api) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await store.refresh(api: api) }
        await Task.yield(); gate.complete(with: data)
        await first.value; await second.value
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(store.students.count, 1); XCTAssertFalse(store.loading)
    }
    func testLockClearsSnapshotAndRejectsLateResponse() async {
        let store = ClasseraDirectoryStore(); let api = api(); let data = response()
        let started = expectation(description: "read started")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        let task = Task { await store.refresh(api: api) }
        await fulfillment(of: [started], timeout: 2)
        api.setAccessAllowed(false); store.clear()
        gate.complete(with: data)
        await task.value
        XCTAssertTrue(store.students.isEmpty); XCTAssertNil(store.error); XCTAssertFalse(store.loading)
    }
    func testRealNetworkFailureRetainsSnapshotAndManualRetryWorks() async {
        let store = ClasseraDirectoryStore(); let api = api(); let first = response()
        MockURLProtocol.handler = { _ in (200, first) }
        await store.refresh(api: api)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await store.refresh(api: api)
        XCTAssertEqual(store.students.first?.phone, "201000000001")
        XCTAssertNotNil(store.error); XCTAssertFalse(store.loading)
        let second = response("201000000002")
        MockURLProtocol.handler = { _ in (200, second) }
        await store.refresh(api: api)
        XCTAssertEqual(store.students.first?.phone, "201000000002"); XCTAssertNil(store.error)
    }
    func testOldCancelledReadCannotOverwriteNewRead() async {
        let store = ClasseraDirectoryStore(); let api = api(); let old = response()
        let started = expectation(description: "old read started")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        let first = Task { await store.refresh(api: api) }
        await fulfillment(of: [started], timeout: 2)
        MockURLProtocol.onStart = nil; store.clear()
        let new = response("201000000002")
        MockURLProtocol.handler = { _ in (200, new) }
        await store.refresh(api: api); gate.complete(with: old); await first.value
        XCTAssertEqual(store.students.first?.phone, "201000000002")
        XCTAssertNil(store.error); XCTAssertFalse(store.loading)
    }
    func testGETCancellationRetainsItsIdentity() async {
        let api = api()
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do { _ = try await api.loadClasseraDirectory(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(ServerAPI.isRefreshCancellation(error)) }
    }
    func testCancelledMutationIsUncertainAndNeverRetried() async throws {
        let api = api()
        let directory = try JSONDecoder().decode(ClasseraDirectoryResponse.self, from: response())
        let student = try XCTUnwrap(directory.students.first)
        let payload = try ClasseraStudentEdit(student: student, rows: [])
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do { _ = try await api.saveClasseraStudent(phone: student.phone, payload: payload); XCTFail("Expected uncertain outcome") }
        catch { XCTAssertEqual(error as? ClasseraDirectoryFailure, .uncertain) }
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
    }
    func testBriefReturnReusesDirectoryButManualPullRefreshes() async {
        let store = ClasseraDirectoryStore(); let api = api(); let data = response()
        MockURLProtocol.handler = { _ in (200, data) }
        await store.refresh(api: api, automatic: true)
        store.clear(removeSnapshot: false)
        api.setAccessAllowed(false, preservingSession: true); api.setAccessAllowed(true)
        await store.refresh(api: api, automatic: true)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(store.students.count, 1)
        await store.refresh(api: api)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }
    func testHardLockCannotReuseDirectorySnapshot() async {
        let store = ClasseraDirectoryStore(); let api = api(); let data = response()
        MockURLProtocol.handler = { _ in (200, data) }
        await store.refresh(api: api, automatic: true)
        store.clear(); api.setAccessAllowed(false); api.setAccessAllowed(true)
        await store.refresh(api: api, automatic: true)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }
    func testConnectionChangeClearsPreviousDirectoryBeforeFetching() async throws {
        let store = ClasseraDirectoryStore(); let api = api(); let data = response()
        MockURLProtocol.handler = { _ in (200, data) }
        await store.refresh(api: api)
        XCTAssertEqual(store.students.count, 1)
        try api.saveConnection(url: "https://other.example", replacementToken: "")
        let started = expectation(description: "new server read started")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        let refresh = Task { await store.refresh(api: api, automatic: true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.students.isEmpty)
        gate.complete(with: response("201000000002")); await refresh.value
        XCTAssertEqual(store.students.first?.phone, "201000000002")
        XCTAssertEqual(MockURLProtocol.requests.last?.url?.host, "other.example")
    }
}
