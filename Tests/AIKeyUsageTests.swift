import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class AIKeyUsageTests: XCTestCase {
    private let suite = "Orbit.AIKeyUsageTests"
    private var defaults: UserDefaults!
    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api() -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
            tokenProvider: { "owner-fixture" }, authorize: { _ in XCTFail("Read-only analytics must not authorize a mutation") })
    }
    private func fixture(days: Int = 7, className: String = "All", waiting: Bool = false) -> Data {
        let total = waiting ? 0 : 8
        let rows: [[String: Any]] = (1...4).map { index in
            ["id": "key-\(index)", "label": "Key \(index)", "configured": true,
             "requests": index == 1 ? total : 0, "successful": index == 1 ? total : 0,
             "failed": 0, "rate_limits": 0, "last_used": index == 1 && !waiting ? ("2026-10-28T10:00:00+03:00" as Any) : NSNull()]
        }
        let points: [[String: Any]] = (22...28).flatMap { day in (1...4).map { key in
            ["day": "2026-10-\(day)", "key_id": "key-\(key)", "label": "Key \(key)", "requests": key == 1 && day == 28 ? total : 0]
        } }
        return try! JSONSerialization.data(withJSONObject: ["version": 1, "state": waiting ? "waiting" : "ready",
            "timezone": "Africa/Cairo", "days": days, "class_name": className, "updated_at": 1793170800,
            "configured_keys": 4, "active_keys_today": waiting ? 0 : 1, "requests_today": total, "rate_limits_today": 0,
            "chart_days": days == 30 ? 30 : 7, "daily": points, "keys": rows,
            "recommendation": waiting ? "Waiting for usage data" : "Only 1 of 4 configured keys used in the last 7 days.", "unmapped_keys": 0])
    }
    func testOwnerGetFiltersAndZeroUsageDecoding() async throws {
        let data = fixture(waiting: true)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/classera/ai-key-usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            XCTAssertNil(request.httpBody)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "days" }?.value, "7")
            XCTAssertEqual(query?.first { $0.name == "class_name" }?.value, "All")
            return (200, data)
        }
        let value = try await api().aiKeyUsage(days: 7, className: "All")
        XCTAssertEqual(value.state, "waiting"); XCTAssertEqual(value.keys.count, 4)
        XCTAssertTrue(value.keys.allSatisfy { $0.requests == 0 && $0.last_used == nil })
    }
    func testInvalidFiltersNeverSendAndBadResponseIsRejected() async throws {
        let api = api()
        do { _ = try await api.aiKeyUsage(days: 3, className: "All"); XCTFail("Invalid filter") } catch { }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        MockURLProtocol.handler = { _ in (200, Data("{}".utf8)) }
        do { _ = try await api.aiKeyUsage(days: 7, className: "All"); XCTFail("Invalid schema") } catch { }
    }
    func testAuthenticationFailureAndCancellationRetainSnapshot() async throws {
        let api = api(); let store = AIKeyUsageStore(); let data = fixture()
        MockURLProtocol.handler = { _ in (200, data) }
        await store.load(api: api, days: 7, className: "All")
        MockURLProtocol.handler = { _ in (401, Data("{}".utf8)) }
        await store.load(api: api, days: 7, className: "All")
        XCTAssertEqual(store.snapshot?.requests_today, 8)
        XCTAssertTrue(store.error?.contains("Authentication failed") == true)
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await store.load(api: api, days: 7, className: "All")
        XCTAssertEqual(store.snapshot?.requests_today, 8)
        XCTAssertNil(store.error)
        store.clear(); XCTAssertNil(store.snapshot)
    }
    func testSimultaneousReadsCoalesce() async throws {
        let api = api(); let store = AIKeyUsageStore(); let data = fixture()
        MockURLProtocol.handler = { _ in (200, data) }
        async let first: Void = store.load(api: api, days: 7, className: "All")
        async let second: Void = store.load(api: api, days: 7, className: "All")
        _ = await (first, second)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(store.snapshot?.requests_today, 8)
    }
    func testUsageChartOnIPhone() async throws {
        let api = api(); let data = fixture()
        MockURLProtocol.handler = { _ in (200, data) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            AIKeyUsageView(api: api)
        }.preferredColorScheme(.dark).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "ai-key-usage-dark"; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true
    }
}
