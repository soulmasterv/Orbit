import XCTest
@testable import Orbit

@MainActor
final class ReadSnapshotFreshnessTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        suite = "ReadSnapshotFreshnessTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/dashboard" { return (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }
            return (200, Data(#"{"gemini":[],"classera":[],"padel":[]}"#.utf8))
        }
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
    func testCacheUsesMonotonicTimeAndExpiresAtOneMinute() {
        let context = UUID(); let start = ContinuousClock.now
        var freshness = ReadSnapshotFreshness()
        XCTAssertFalse(freshness.isFresh(context: context, at: start))
        freshness.record(context: context, at: start)
        XCTAssertTrue(freshness.isFresh(context: context, at: start.advanced(by: .seconds(59))))
        XCTAssertFalse(freshness.isFresh(context: context, at: start.advanced(by: .seconds(60))))
        XCTAssertFalse(freshness.isFresh(context: UUID(), at: start))
        XCTAssertFalse(freshness.isFresh(context: context, at: start.advanced(by: .seconds(-1))))
        freshness.expire()
        XCTAssertTrue(freshness.belongs(to: context))
        XCTAssertFalse(freshness.isFresh(context: context, at: start))
        freshness.clear(); XCTAssertFalse(freshness.isFresh(context: context, at: start))
        XCTAssertFalse(freshness.belongs(to: context))
    }
    func testBriefSuspensionKeepsFreshReadsButAlwaysDeniesBackgroundActions() async {
        let api = api(); await api.refreshAll()
        XCTAssertTrue(api.canControl)
        let before = MockURLProtocol.requests.count; let context = api.latestReportsContext
        api.setAccessAllowed(false, preservingSession: true)
        XCTAssertFalse(api.accessAllowed); XCTAssertFalse(api.canControl)
        XCTAssertTrue(api.retainsReadSnapshots); XCTAssertEqual(api.latestReportsContext, context)
        await api.refreshIfNeeded(); XCTAssertEqual(MockURLProtocol.requests.count, before)
        api.setAccessAllowed(true); await api.refreshIfNeeded()
        XCTAssertEqual(MockURLProtocol.requests.count, before); XCTAssertTrue(api.canControl)
        await api.refreshAll() // Explicit refresh still forces both reads.
        XCTAssertEqual(MockURLProtocol.requests.count, before + 2)
    }
    func testRealLockWhileAlreadySuspendedInvalidatesContextAndRequiresVerification() async {
        let api = api(); await api.refreshAll()
        let context = api.latestReportsContext
        api.setAccessAllowed(false, preservingSession: true)
        api.setAccessAllowed(false) // Five-minute expiry may happen in background.
        XCTAssertFalse(api.retainsReadSnapshots); XCTAssertNotEqual(api.latestReportsContext, context)
        api.setAccessAllowed(true); XCTAssertFalse(api.canControl)
        let before = MockURLProtocol.requests.count
        await api.refreshIfNeeded()
        XCTAssertEqual(MockURLProtocol.requests.count, before + 2); XCTAssertTrue(api.canControl)
    }
    func testStaleAutomaticReadLoadsAgainWithoutSleepingAMinute() async {
        let api = api(); await api.refreshAll()
        let afterFirst = ContinuousClock.now
        let before = MockURLProtocol.requests.count
        await api.refreshIfNeeded(at: afterFirst.advanced(by: .seconds(61)))
        XCTAssertEqual(MockURLProtocol.requests.count, before + 2)
    }
    func testConnectionChangeCannotReusePreviousServerSnapshot() async throws {
        let api = api(); await api.refreshAll()
        let context = api.latestReportsContext
        try api.saveConnection(url: "https://other.example", replacementToken: "")
        XCTAssertNotEqual(api.latestReportsContext, context)
        XCTAssertNil(api.dashboard); XCTAssertNil(api.serviceSnapshot)
        let before = MockURLProtocol.requests.count
        await api.refreshIfNeeded()
        XCTAssertEqual(MockURLProtocol.requests.count, before + 2)
        XCTAssertTrue(MockURLProtocol.requests.suffix(2).allSatisfy { $0.url?.host == "other.example" })
    }
    func testReadStartedBeforeSuspensionCannotCommitAfterResumeWithSameCacheContext() async {
        let api = api(); let gate = DashboardRequestGate()
        let started = expectation(description: "directory read started")
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        let read = Task { try await api.loadClasseraDirectory() }
        await fulfillment(of: [started], timeout: 2)
        let context = api.latestReportsContext
        api.setAccessAllowed(false, preservingSession: true); api.setAccessAllowed(true)
        XCTAssertEqual(api.latestReportsContext, context)
        gate.complete(with: Data(#"{"version":1,"students":[]}"#.utf8))
        do { _ = try await read.value; XCTFail("Old access epoch must not commit") }
        catch { XCTAssertTrue(ServerAPI.isRefreshCancellation(error)) }
    }
    func testMonitoringResumeUsesSnapshotButManualRefreshStillReads() async {
        let api = api()
        MockURLProtocol.handler = { _ in (200, Data(#"{"version":1,"classes":[],"updated_at":1,"sending_enabled":true,"notice":"Fixture"}"#.utf8)) }
        let store = ClasseraMonitoringStore(loadPending: { nil }, savePending: { _ in })
        await store.load(api: api, tab: 0, automatic: true)
        XCTAssertNotNil(store.waiting)
        let before = MockURLProtocol.requests.count
        store.clear(preserveReadSnapshots: true)
        api.setAccessAllowed(false, preservingSession: true); api.setAccessAllowed(true)
        await store.load(api: api, tab: 0, automatic: true)
        XCTAssertEqual(MockURLProtocol.requests.count, before)
        XCTAssertNil(store.preview); XCTAssertFalse(store.vaultReady)
        await store.load(api: api, tab: 0)
        XCTAssertEqual(MockURLProtocol.requests.count, before + 1)
    }
}
