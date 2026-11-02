import XCTest
@testable import Orbit

@MainActor
final class SessionScreenCacheTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        suite = "SessionScreenCacheTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Preloading must never submit actions")
            switch request.url?.path {
            case "/api/dashboard": return (200, try JSONEncoder().encode(PreviewFixtures.dashboard))
            case "/api/classera-students": return (200, Data(#"{"version":1,"students":[]}"#.utf8))
            case "/api/classera/ai-key-usage":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let days = Int(query.first { $0.name == "days" }?.value ?? "7")!
                let label = query.first { $0.name == "class_name" }?.value ?? "All"
                return (200, Self.usage(days: days, className: label))
            case "/api/classera/waiting-list":
                return (200, Data(#"{"version":1,"classes":[],"updated_at":1,"sending_enabled":true,"notice":"Fixture"}"#.utf8))
            default: return (200, Data(#"{"gemini":[],"classera":[],"padel":[]}"#.utf8))
            }
        }
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api(token: String = "owner-fixture", allowed: Bool = true, allowAuthorization: Bool = false) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults, accessAllowed: allowed,
                         tokenProvider: { token }, authorize: { _ in if !allowAuthorization { XCTFail("Reads must not request device authorization") } })
    }
    private static func usage(days: Int = 7, className: String = "All") -> Data {
        Data("""
        {"version":1,"state":"ready","timezone":"Africa/Cairo","days":\(days),"class_name":"\(className)",
        "updated_at":1,"configured_keys":0,"active_keys_today":0,"requests_today":0,"rate_limits_today":0,
        "chart_days":\(days == 30 ? 30 : 7),"daily":[],"keys":[],"recommendation":"Fixture","unmapped_keys":0}
        """.utf8)
    }
    func testSnapshotKeysContextsExpiryAndCapacityAreBounded() {
        let cache = ScreenSnapshotCache<Int>(); let context = UUID(); let start = ContinuousClock.now
        cache.record(7, for: "folder-a", context: context, at: start)
        XCTAssertEqual(cache.value(for: "folder-a", context: context, freshOnly: true, at: start.advanced(by: .seconds(59))), 7)
        XCTAssertNil(cache.value(for: "folder-a", context: context, freshOnly: true, at: start.advanced(by: .seconds(60))))
        XCTAssertEqual(cache.value(for: "folder-a", context: context), 7, "Stale data can stay visible during revalidation")
        XCTAssertNil(cache.value(for: "folder-b", context: context))
        XCTAssertNil(cache.value(for: "folder-a", context: UUID()))
        for i in 0..<16 { cache.record(i, for: "other-\(i)", context: context) }
        XCTAssertNil(cache.value(for: "folder-a", context: context))
        cache.clear(); XCTAssertNil(cache.value(for: "other-15", context: context))
    }
    func testPreloadUsesOnlyTwoOwnerReadsAndOpeningScreensReusesThem() async {
        let server = api(); await server.preloadCommonScreens()
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer owner-fixture" && $0.value(forHTTPHeaderField: "X-API-Key") == nil })
        await server.classeraDirectoryStore.refresh(api: server, automatic: true)
        await server.keyUsageStore.load(api: server, days: 7, className: "All", automatic: true)
        await server.preloadCommonScreens()
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertNotNil(server.keyUsageStore.snapshot)
    }
    func testPreloadDoesNothingWhileLockedOrWithoutOwnerCredentials() async {
        await api(allowed: false).preloadCommonScreens()
        await api(token: "").preloadCommonScreens()
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testPreloadDoesNotReplaceAnAlreadySelectedUsageFilter() async {
        let server = api()
        await server.keyUsageStore.load(api: server, days: 30, className: "12E", automatic: true)
        await server.preloadCommonScreens()
        XCTAssertEqual(server.keyUsageStore.snapshot?.days, 30)
        XCTAssertEqual(server.keyUsageStore.snapshot?.class_name, "12E")
        XCTAssertEqual(MockURLProtocol.requests.count, 2, "Only the directory is still missing")
    }
    func testBriefBackgroundResumeKeepsPreloadedDataButDeniesBackgroundReads() async {
        let server = api(); await server.preloadCommonScreens()
        let count = MockURLProtocol.requests.count
        server.setAccessAllowed(false, preservingSession: true)
        await server.preloadCommonScreens()
        XCTAssertEqual(MockURLProtocol.requests.count, count)
        XCTAssertNotNil(server.keyUsageStore.snapshot)
        server.setAccessAllowed(true); await server.preloadCommonScreens()
        await server.keyUsageStore.load(api: server, days: 7, className: "All", automatic: true)
        XCTAssertEqual(MockURLProtocol.requests.count, count)
    }
    func testRealLockPurgesSharedSnapshotsAndNextUnlockPreloadsAgain() async {
        let server = api(); await server.preloadCommonScreens()
        let context = server.latestReportsContext
        server.downloadsCache.record(OrbitDownloadsResponse(version: 1, items: [], truncated: false, nextCursor: nil), for: "root", context: context)
        server.setAccessAllowed(false)
        XCTAssertNil(server.keyUsageStore.snapshot)
        XCTAssertNil(server.downloadsCache.value(for: "root", context: context))
        XCTAssertNotEqual(server.latestReportsContext, context)
        server.setAccessAllowed(true); await server.preloadCommonScreens()
        XCTAssertEqual(MockURLProtocol.requests.count, 4)
    }
    func testConnectionChangeCannotReusePreloadOrCachedFolder() async throws {
        let server = api(); await server.preloadCommonScreens()
        let context = server.latestReportsContext
        server.downloadsCache.record(OrbitDownloadsResponse(version: 1, items: [], truncated: false, nextCursor: nil), for: "root", context: context)
        try server.saveConnection(url: "https://different.example", replacementToken: "")
        XCTAssertNil(server.keyUsageStore.snapshot)
        XCTAssertNil(server.downloadsCache.value(for: "root", context: context))
        await server.preloadCommonScreens()
        XCTAssertEqual(MockURLProtocol.requests.count, 4)
        XCTAssertTrue(MockURLProtocol.requests.suffix(2).allSatisfy { $0.url?.host == "different.example" })
    }
    func testUsageFilterReturnUsesMatchingSnapshotAndManualRefreshStillReads() async {
        let server = api(); let store = server.keyUsageStore
        await store.load(api: server, days: 7, className: "All", automatic: true)
        await store.load(api: server, days: 30, className: "12F", automatic: true)
        await store.load(api: server, days: 7, className: "All", automatic: true)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(store.snapshot?.days, 7); XCTAssertEqual(store.snapshot?.class_name, "All")
        await store.load(api: server, days: 7, className: "All")
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
    }
    func testRecreatedMonitoringStoreReusesReadButNotPreviewOrAuthorizationState() async {
        let server = api()
        let first = ClasseraMonitoringStore(loadPending: { nil }, savePending: { _ in })
        await first.load(api: server, tab: 0, automatic: true)
        XCTAssertNotNil(first.waiting)
        let count = MockURLProtocol.requests.count
        let reopened = ClasseraMonitoringStore(loadPending: { nil }, savePending: { _ in })
        await reopened.load(api: server, tab: 0, automatic: true)
        XCTAssertNotNil(reopened.waiting); XCTAssertNil(reopened.preview); XCTAssertFalse(reopened.vaultReady)
        XCTAssertEqual(MockURLProtocol.requests.count, count)
        await reopened.load(api: server, tab: 0)
        XCTAssertEqual(MockURLProtocol.requests.count, count + 1)
    }
    func testStudentListDetailVisibilityTransferKeepsFreshReadVerification() async {
        let server = api(); var reads = 0
        let store = StudentsStore(api: server, connectionProvider: { StudentsConnection(baseURL: "https://school.example", apiKey: "school-fixture") }, fetchSnapshot: { _ in
            reads += 1; return StudentsSnapshot(students: [], receivedAt: Date())
        })
        store.claimVisibility(UUID()); await store.refreshIfNeeded()
        store.claimVisibility(UUID()); await store.refreshIfNeeded()
        XCTAssertEqual(reads, 1); XCTAssertFalse(store.requiresVerification)
        await store.refresh(); XCTAssertEqual(reads, 2)
    }
    func testAddingStudentInvalidatesFreshDirectoryInsteadOfHidingNewProfile() async throws {
        let server = api(allowAuthorization: true); let store = server.classeraDirectoryStore
        await store.refresh(api: server, automatic: true)
        let row: [String: Any] = ["phone":"201000000001", "profile_name":"New fixture", "activity_status":"allowed",
            "revision":String(repeating:"a",count:64), "subscriptions":[], "signup_session":NSNull()]
        let created = try JSONSerialization.data(withJSONObject: row)
        let listing = try JSONSerialization.data(withJSONObject: ["version":1,"students":[row]])
        MockURLProtocol.handler = { request in (200, request.httpMethod == "POST" ? created : listing) }
        _ = try await server.createClasseraProfile(phone: "201000000001", name: "New fixture")
        XCTAssertEqual(server.classeraDirectoryRevision, 1)
        await store.refresh(api: server, automatic: true)
        XCTAssertEqual(store.students.first?.phone, "201000000001")
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
    }
    func testHiddenSchoolDirectoryIsPurgedSynchronouslyOnRealLock() async {
        let server = api(); var reads = 0
        let store = StudentsStore(api: server, connectionProvider: { StudentsConnection(baseURL: "https://school.example", apiKey: "school-fixture") }, fetchSnapshot: { _ in
            reads += 1; return StudentsSnapshot(students: [], receivedAt: Date())
        })
        await store.refreshIfNeeded(); XCTAssertNotNil(store.snapshot)
        server.setAccessAllowed(false, preservingSession: true)
        XCTAssertNotNil(store.snapshot)
        server.setAccessAllowed(false) // Expiry while backgrounded, even if School isn't visible.
        XCTAssertNil(store.snapshot); XCTAssertTrue(store.requiresVerification)
        server.setAccessAllowed(true); await store.refreshIfNeeded()
        XCTAssertEqual(reads, 2)
    }
    func testCachedUsageFilterCannotBeOverwrittenByOlderInFlightFilter() async {
        let server = api(); let store = server.keyUsageStore
        await store.load(api: server, days: 7, className: "All", automatic: true)
        let gate = DashboardRequestGate(); let started = expectation(description: "older filter started")
        MockURLProtocol.onStart = { request in gate.capture(request); started.fulfill() }
        let older = Task { await store.load(api: server, days: 30, className: "12F", automatic: true) }
        await fulfillment(of: [started], timeout: 2)
        await store.load(api: server, days: 7, className: "All", automatic: true)
        gate.complete(with: Self.usage(days: 30, className: "12F")); await older.value
        XCTAssertEqual(store.snapshot?.days, 7); XCTAssertEqual(store.snapshot?.class_name, "All")
        XCTAssertFalse(store.loading)
    }
}
