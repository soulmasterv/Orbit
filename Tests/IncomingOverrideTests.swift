import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor final class IncomingOverrideTests: XCTestCase {
    private func fixture(active: Bool) throws -> Data {
        var value: [String: Any] = ["version": 1, "availableModes": ["jarvis", "silly", "bibo", "diaa", "diaa-noqta"],
            "availableOverrideModes": ["silly", "bibo", "diaa", "diaa-noqta"],
            "callers": [["number": "+201000000002", "name": "Ahmed fixture", "enabled": true,
                         "modes": ["silly", "diaa"], "defaultMode": "silly", "selectedMode": "diaa"]]]
        if active { value["override"] = ["mode": "bibo", "expiresAt": Date().addingTimeInterval(590).timeIntervalSince1970 * 1000] as [String: Any] }
        else { value["override"] = NSNull() }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func value(active: Bool) throws -> OrbitAllowedCallers { try JSONDecoder().decode(OrbitAllowedCallers.self, from: fixture(active: active)) }
    override func tearDown() async throws { MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil; MockURLProtocol.requests = [] }

    func testExpiryIsUnixMillisecondsAndCountdownUsesServerExpiry() {
        let value = OrbitIncomingOverride(mode: "diaa", expiresAt: 1_800_000_000_000)
        XCTAssertEqual(value.expires.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(value.remaining(at: value.expires.addingTimeInterval(-61)), 61)
        XCTAssertEqual(value.countdown(at: value.expires.addingTimeInterval(-61)), "1:01 remaining")
        XCTAssertEqual(value.countdown(at: value.expires), "Checking server expiry…")
        XCTAssertEqual(value.remaining(at: value.expires.addingTimeInterval(60)), 0)
    }
    func testMissingOverrideFieldsRemainCompatibleAndPrivateModeIsFiltered() throws {
        let old = try JSONDecoder().decode(OrbitAllowedCallers.self, from: Data(#"{"version":1,"availableModes":["jarvis"],"callers":[]}"#.utf8))
        XCTAssertNil(old.incomingOverride); XCTAssertTrue(old.overrideModes.isEmpty)
        var value = try value(active: false); value.availableOverrideModes = ["jarvis", "silly", "future-mode", "diaa"]
        XCTAssertEqual(value.overrideModes, ["silly", "diaa"])
    }
    func testCustomDurationAcceptsOnlyWholeMinutesWithinBounds() {
        for input in ["1", "5", "120"] { XCTAssertEqual(OrbitIncomingOverrideChange.customMinutes(input), Int(input)) }
        for input in ["", "0", "121", "-1", "1.5", " 5 ", "1e1", "١٠", "999999999999999999999999"] {
            XCTAssertNil(OrbitIncomingOverrideChange.customMinutes(input))
        }
    }
    func testStartStopPayloadsAreMinimalAndNeverAllowJarvisOrCallerEdits() throws {
        let start = OrbitIncomingOverrideChange(action: "override", mode: "diaa", minutes: 10)
        XCTAssertTrue(start.isValid)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(start)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["action", "mode", "minutes"])
        XCTAssertEqual(body["mode"] as? String, "diaa"); XCTAssertEqual(body["minutes"] as? Int, 10)
        let stop = OrbitIncomingOverrideChange(action: "clear_override")
        XCTAssertTrue(stop.isValid)
        let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stop)) as? [String: Any])
        XCTAssertEqual(Set(cleared.keys), ["action"])
        for mode in ["jarvis", "unknown"] { XCTAssertFalse(OrbitIncomingOverrideChange(action: "override", mode: mode, minutes: 10).isValid) }
        XCTAssertFalse(OrbitIncomingOverrideChange(action: "override", mode: "diaa", minutes: 121).isValid)
        XCTAssertFalse(OrbitIncomingOverrideChange(action: "clear_override", mode: "diaa").isValid)
    }
    func testExpiryDoesNotLocallyClearOverrideAndServerNullRestoresSavedPreferences() async throws {
        let state = OrbitAllowedCallersState(); var active = try value(active: true)
        active.incomingOverride = OrbitIncomingOverride(mode: "bibo", expiresAt: 1)
        await state.load { active }
        XCTAssertNotNil(state.snapshot?.incomingOverride)
        XCTAssertEqual(state.snapshot?.callers[0].currentMode, "diaa")
        let restored = try value(active: false); await state.load { restored }
        XCTAssertNil(state.snapshot?.incomingOverride)
        XCTAssertEqual(state.snapshot?.callers, active.callers)
    }
    func testUncertainStopRetainsServerSnapshotAndRequiresRefresh() async throws {
        let state = OrbitAllowedCallersState(), active = try value(active: true); await state.load { active }
        var calls = 0
        _ = await state.apply { calls += 1; throw URLError(.timedOut) }
        _ = await state.apply { calls += 1; return active }
        XCTAssertEqual(calls, 1); XCTAssertNotNil(state.snapshot?.incomingOverride); XCTAssertTrue(state.needsRefresh)
    }
    private func api(_ defaults: UserDefaults, authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults, tokenProvider: { "override-fixture" }, authorize: authorize, phonePilotIsForeground: { true })
    }
    func testStartAndStopUseBearerProxyAndReturnedStateWithoutOutgoingQueue() async throws {
        let suite = "IncomingOverrideTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = api(defaults), data = try fixture(active: true)
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }; await api.loadDashboard()
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/jarvis/allowed-callers"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer override-fixture")
            return (200, data)
        }
        let result = try await api.changeIncomingOverride(OrbitIncomingOverrideChange(action: "override", mode: "diaa", minutes: 10))
        XCTAssertEqual(result.incomingOverride?.mode, "bibo", "Render returned state rather than guessing from the submitted mode")
        _ = try await api.changeIncomingOverride(OrbitIncomingOverrideChange(action: "clear_override"))
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        do { _ = try await api.changeIncomingOverride(OrbitIncomingOverrideChange(action: "override", mode: "jarvis", minutes: 10)); XCTFail() } catch { }
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }
    func testLockDuringAuthorizationPreventsOverridePost() async throws {
        let suite = "IncomingOverrideTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var instance: ServerAPI!; instance = api(defaults, authorize: { _ in instance.setAccessAllowed(false) })
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }; await instance.loadDashboard()
        MockURLProtocol.requests = []
        do { _ = try await instance.changeIncomingOverride(OrbitIncomingOverrideChange(action: "clear_override")); XCTFail() } catch { }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty); XCTAssertFalse(instance.actionBusy)
    }
    func testInactiveAndActiveCardsUseOnlyFixtureReads() async throws {
        let suite = "IncomingOverrideTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = api(defaults)
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }; await api.loadDashboard()
        MockURLProtocol.requests = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for active in [false, true] {
            let data = try fixture(active: active)
            MockURLProtocol.handler = { request in XCTAssertEqual(request.httpMethod, "GET"); return (200, data) }
            let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: NavigationStack { OrbitAllowedCallersView(api: api) }.preferredColorScheme(.dark).environment(\.scenePhase, .active))
            window.makeKeyAndVisible(); let ready = expectation(description: "Override card")
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { ready.fulfill() }; await fulfillment(of: [ready], timeout: 5)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = active ? "incoming-override-active" : "incoming-override-ready"; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }
}
