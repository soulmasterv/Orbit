import XCTest
import SwiftUI
import UIKit
@testable import Orbit

final class OrbitWindowEvidenceTests: XCTestCase {
    func testClosedDoesNotRequireAnInboundTimestamp() throws {
        let value = try JSONDecoder().decode(ClasseraWhatsAppWindow.self,
            from: Data(#"{"class_name":"12F","window_open":false,"seconds_left":0}"#.utf8))
        let instant = ContinuousClock.now
        XCTAssertEqual(value.remainingSeconds(since: instant, at: instant), 0)
        XCTAssertEqual(value.displayLabel(since: instant, at: instant), "Closed")
    }
    func testOpenUsesExplicitServerSecondsWhenOptionalTimestampIsMissing() throws {
        let value = try JSONDecoder().decode(ClasseraWhatsAppWindow.self,
            from: Data(#"{"class_name":"12F","window_open":true,"seconds_left":5400}"#.utf8))
        let instant = ContinuousClock.now
        XCTAssertEqual(value.remainingSeconds(since: instant, at: instant), 5400)
        XCTAssertEqual(value.displayLabel(since: instant, at: instant, receivedAt: Date(timeIntervalSince1970: 21 * 3600),
            timeZone: TimeZone(secondsFromGMT: 0)!), "Open until 10:30 PM")
        XCTAssertEqual(value.displayLabel(since: instant, at: instant.advanced(by: .seconds(5400))), "Closed")
        XCTAssertNil(value.canSendPlaintext) // Display evidence never grants permission to send.
    }
    func testMissingMalformedAndContradictoryEvidenceStayUnknown() throws {
        for json in [
            #"{"class_name":"12F"}"#,
            #"{"class_name":"12F","window_open":null,"seconds_left":null}"#,
            #"{"class_name":"12F","window_open":"true","seconds_left":3600}"#,
            #"{"class_name":"12F","window_open":true,"seconds_left":-1}"#,
            #"{"class_name":"12F","window_open":true,"seconds_left":86401}"#,
            #"{"class_name":"12F","window_open":false,"seconds_left":300}"#
        ] {
            let value = try JSONDecoder().decode(ClasseraWhatsAppWindow.self, from: Data(json.utf8))
            XCTAssertNil(value.remainingSeconds(since: .now))
            XCTAssertEqual(value.displayLabel(since: .now), "Unknown")
        }
    }
    func testSchoolUnknownIsNeitherOpenNorClosedRegardlessOfOtherStatuses() throws {
        let data = Data(#"[{"phone":"201000000001","state":"active","activity_status":"allowed","name":"Fixture","grade":"12"},{"phone":"201000000002","state":"active","window_open":false,"seconds_left":0}]"#.utf8)
        let rows = try JSONDecoder().decode([Student].self, from: data)
        let snapshot = StudentsSnapshot(students: rows, receivedAt: Date())
        XCTAssertEqual(snapshot.windowState(for: rows[0]), .unknown)
        XCTAssertFalse(snapshot.isWindowOpen(for: rows[0]))
        XCTAssertEqual(snapshot.windowLabel(for: rows[0]), "Window unknown")
        XCTAssertEqual(StudentsDirectory.filtered(snapshot, search: "", filter: .closed, grade: "").map(\.phone), [rows[1].phone])
        XCTAssertEqual(StudentsDirectory.filtered(snapshot, search: "", filter: .unknown, grade: "").map(\.phone), [rows[0].phone])
    }
    func testBuildMetadataUsesBundleValuesAndNeverInventsBuildOne() {
        XCTAssertEqual(OrbitBuildInfo(info: ["CFBundleShortVersionString":"4.1.0","CFBundleVersion":"89"]).label, "Version 4.1.0 · Build 89")
        XCTAssertEqual(OrbitBuildInfo(info: [:]).build, "Unavailable")
        XCTAssertFalse(OrbitChangelogEntry.entries.isEmpty)
        XCTAssertEqual(Set(OrbitChangelogEntry.entries.map(\.id)).count, OrbitChangelogEntry.entries.count)
    }
}

@MainActor
final class OrbitWindowLoadingTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "Orbit.NextUpdateTests"
    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.onStart = nil; MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in XCTFail("These fixture tests must not contact any API"); throw URLError(.cancelled) }
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api() -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
            tokenProvider: { "owner-fixture" }, authorize: { _ in XCTFail("Read-only window checks cannot authorize a mutation") })
    }
    private func response(_ phone: String) -> ClasseraMessagingResponse {
        .init(version: 1, phone: phone, whatsappWindows: [
            .init(className: "12F", windowOpen: false, secondsLeft: 0, lastInboundAt: nil)])
    }
    func testNetworkFailureIsVisibleAndRetryIsExplicit() async {
        let api = api(); var calls = 0
        let store = ClasseraWindowStore(fetch: { phone in
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            return self.response(phone)
        })
        await store.refresh(api: api, phone: "201000000001")
        XCTAssertEqual(calls, 1); XCTAssertNotNil(store.error); XCTAssertFalse(store.loading)
        await store.refresh(api: api, phone: "201000000001")
        XCTAssertEqual(calls, 2); XCTAssertNil(store.error)
        XCTAssertEqual(store.response?.whatsappWindows.first?.windowOpen, false)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testAuthenticationFailureIsSeparateAndDoesNotExposeRawResponse() async {
        let store = ClasseraWindowStore(fetch: { _ in throw HTTPFailure(status: 401) })
        await store.refresh(api: api(), phone: "201000000001")
        XCTAssertTrue(store.error?.contains("Authentication failed") == true)
        XCTAssertNil(store.response)
    }
    func testConcurrentWindowChecksCoalesceWithoutMutations() async {
        let api = api(); var calls = 0
        let store = ClasseraWindowStore(fetch: { phone in
            calls += 1
            await Task.yield()
            return self.response(phone)
        })
        async let first: Void = store.refresh(api: api, phone: "201000000001")
        async let second: Void = store.refresh(api: api, phone: "201000000001")
        _ = await (first, second)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testLockPreventsFetchAndAnOlderResponseCannotRestoreClearedState() async {
        let api = api(); let entered = expectation(description: "Fixture fetch entered")
        var continuation: CheckedContinuation<ClasseraMessagingResponse, Error>?
        var calls = 0
        let store = ClasseraWindowStore(fetch: { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0; entered.fulfill() }
        })
        let request = Task { await store.refresh(api: api, phone: "201000000001") }
        await fulfillment(of: [entered], timeout: 2)
        api.setAccessAllowed(false); store.clear()
        continuation?.resume(returning: response("201000000001"))
        await request.value
        XCTAssertNil(store.response); XCTAssertFalse(store.loading)
        await store.refresh(api: api, phone: "201000000001")
        XCTAssertEqual(calls, 1)
    }
    func testNavigationAndScrollMemorySurviveLockWithoutAuthorizingAccess() async {
        let api = api(); let navigation = OrbitNavigationState(selectedTab: 2)
        navigation.homePath.append(DetailRoute.service(.gemini))
        navigation.studentsPath.append(ClasseraStudentRoute(phone: "201000000001"))
        navigation.remember("subscriptions", for: "fixture-detail")
        defaults.set(true, forKey: "appLock.v4")
        var uptime: TimeInterval = 10; var unlocks = 0
        let session = AppSession(defaults: defaults, uptime: { uptime }, authenticate: { unlocks += 1 })
        await session.activate(); XCTAssertEqual(unlocks, 1)
        uptime += 301; session.expireIfNeeded(); api.setAccessAllowed(false)
        XCTAssertFalse(session.isUnlocked)
        navigation.remember(nil, for: "fixture-detail")
        XCTAssertEqual(navigation.anchor(for: "fixture-detail"), "subscriptions")
        XCTAssertEqual(navigation.selectedTab, 2)
        XCTAssertEqual(navigation.homePath.count, 1); XCTAssertEqual(navigation.studentsPath.count, 1)
        await session.activate()
        XCTAssertEqual(unlocks, 2); XCTAssertTrue(session.isUnlocked)
        XCTAssertFalse(api.accessAllowed) // Presentation state is not API authorization.
        XCTAssertEqual(navigation.selectedTab, 2)
    }
}
