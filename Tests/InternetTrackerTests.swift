import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor final class InternetTrackerTests: XCTestCase {
    func testDirectoryKeepsDisabledUsersAndBothSavedLines() throws {
        let data = Data(#"{"version":1,"contacts":[{"phone":"201000000002","name":"Saved contact","allowed":false,"lines":[{"number":"0223456789","provider":"vodafone"},{"number":"0334567890","provider":"we"}]},{"phone":"201000000001","name":null,"allowed":true,"lines":[]}]}"#.utf8)
        let value = try JSONDecoder().decode(InternetTrackerDirectory.self, from: data)
        XCTAssertEqual(value.contacts.count, 2); XCTAssertFalse(value.contacts[0].allowed)
        XCTAssertEqual(value.contacts[0].title, "Saved contact"); XCTAssertEqual(value.contacts[0].lines.count, 2)
        XCTAssertEqual(value.contacts[1].title, "201000000001"); XCTAssertTrue(value.contacts[1].lines.isEmpty)
    }
    func testWiFiDirectoryNativeLayoutUsesOnlyAuthenticatedGET() async throws {
        let suite = "WiFiDirectoryLayout.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let api = ServerAPI(session: URLSession(configuration: config), defaults: defaults,
                            tokenProvider: { "fixture-owner" }, authorize: { _ in })
        let fixture = Data(#"{"version":1,"contacts":[{"phone":"201000000001","name":"Saved user A","allowed":true,"lines":[{"number":"0223456789","provider":"vodafone"},{"number":"0334567890","provider":"we"}]},{"phone":"201000000002","name":null,"allowed":false,"lines":[{"number":"0445678901","provider":"we"}]}]}"#.utf8)
        var reads = 0; var writes = 0
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/jarvis/internet/contacts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-owner")
            if request.httpMethod == "GET" { reads += 1 } else { writes += 1 }
            return (200, fixture)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: NavigationStack { OrbitWiFiView(api: api) }
            .preferredColorScheme(.dark).environment(\.scenePhase, .active))
        window.makeKeyAndVisible(); defer { window.isHidden = true; window.rootViewController = nil }
        let ready = expectation(description: "WiFi directory loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 4); window.layoutIfNeeded()
        XCTAssertGreaterThan(reads, 0); XCTAssertEqual(writes, 0)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "wifi-existing-users-dark"
        attachment.lifetime = .keepAlways; add(attachment)
    }
    private func snapshot(operation: String? = nil, pending: Bool = false) throws -> InternetTrackerSnapshot {
        var value: [String: Any] = ["version": 1, "phone": "201000000001", "allowed": true,
            "permissionGranted": true, "permissionEditable": true, "friendChecksEnabled": true,
            "revision": String(repeating: "a", count: 64), "policy": "fixture-v1", "audioProvider": "Fixture",
            "lines": [], "pending": pending, "history": []]
        if let operation { value["operation"] = operation }
        return try JSONDecoder().decode(InternetTrackerSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testLandlinesAcceptLocalAndInternationalFormattingOnly() {
        for input in ["0234567890", "+20 2 3456 7890", "0020 (2) 3456-7890"] {
            XCTAssertEqual(InternetTrackerFormat.landline(input), "0234567890")
        }
        for input in ["01012345678", "abc0234567890", "0234", "0234567890/path"] {
            XCTAssertNil(InternetTrackerFormat.landline(input))
        }
    }
    func testChecksNeedExplicitDeliveryAndConsentAndKeepStableRequestID() {
        var change = InternetTrackerChange(action: "check", revision: String(repeating: "a", count: 64))
        let id = change.request_id; change.slot = 2
        XCTAssertFalse(change.valid)
        change.channel = "sms"; change.policy = "fixture-v1"; change.confirmed = true
        XCTAssertTrue(change.valid); XCTAssertEqual(change.request_id, id)
        change.channel = "push"; XCTAssertFalse(change.valid)
    }
    func testUnknownAllowanceAndZeroRemainDistinct() throws {
        func event(_ remaining: String) throws -> InternetTrackerSnapshot.Event {
            try JSONDecoder().decode(InternetTrackerSnapshot.Event.self, from: Data("""
            {"id":"fixture","number":"0234567890","provider":"we","status":"completed","remaining":\(remaining),"recordingAvailable":false,"recordingExpired":true,"channel":"sms"}
            """.utf8))
        }
        XCTAssertEqual(try event("null").allowance, "Couldn’t read the remaining allowance.")
        XCTAssertEqual(try event("[]").allowance, "Couldn’t read the remaining allowance.")
        XCTAssertEqual(try event(#"[{"amount":"0","unit":"GB"}]"#).allowance, "0 GB remaining")
        XCTAssertFalse(try event(#"[{"amount":"10","unit":"%"}]"#).hasAllowance)
        XCTAssertTrue(try event("null").expired())
    }
    func testDisplayUsesTwelveHourTimeWithoutTimezoneCaption() {
        let text = InternetTrackerFormat.time(1_800_000_000_000)
        XCTAssertTrue(text.contains("AM") || text.contains("PM"))
        XCTAssertFalse(text.contains("Cairo")); XCTAssertEqual(InternetTrackerFormat.time(nil), "Unavailable")
    }
    func testPendingContactPreventsSecondSlotCheckAndSettingsNeverQueue() async throws {
        let state = InternetTrackerStore(); let pending = try snapshot(pending: true)
        await state.load { pending }
        var change = InternetTrackerChange(action: "check", revision: pending.revision)
        change.slot = 2; change.channel = "whatsapp"; change.confirmed = true; change.policy = pending.policy
        var submissions = 0
        let accepted = await state.submit(change) { _ in submissions += 1; return pending }
        XCTAssertFalse(accepted); XCTAssertEqual(submissions, 0)
        state.clear(); XCTAssertNil(state.value)
    }
    func testUncertainResponseDoesNotAutomaticallyRetry() async throws {
        let state = InternetTrackerStore(); let initial = try snapshot()
        await state.load { initial }
        var change = InternetTrackerChange(action: "permission", revision: initial.revision); change.enabled = false
        var count = 0
        let first = await state.submit(change) { _ in count += 1; throw URLError(.timedOut) }
        let second = await state.submit(change) { _ in count += 1; return initial }
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertEqual(count, 1); XCTAssertTrue(state.uncertain)
        await state.load { initial }; XCTAssertFalse(state.uncertain)
    }
    func testNativeTrackerLayoutLoadsBothProvidersWithoutAnyMutation() async throws {
        let suite = "InternetTrackerLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let api = ServerAPI(session: URLSession(configuration: config), defaults: defaults,
                            tokenProvider: { "fixture-owner" }, authorize: { _ in })
        let sample: [String: Any] = ["version": 1, "phone": "201000000001", "allowed": true,
            "permissionGranted": true, "permissionEditable": true, "friendChecksEnabled": true,
            "revision": String(repeating: "a", count: 64), "policy": "fixture-v1", "audioProvider": "Fixture",
            "lines": [["slot": 1, "number": "0223456789", "provider": "vodafone", "weekly": true,
                       "nextAt": 1_800_000_000_000, "channel": "whatsapp"],
                      ["slot": 2, "number": "0334567890", "provider": "we", "weekly": false]],
            "pending": false, "history": []]
        let data = try JSONSerialization.data(withJSONObject: sample)
        var reads = 0; var writes = 0
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" { reads += 1 } else { writes += 1 }
            return (200, data)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            InternetTrackerView(api: api, phone: "201000000001")
        }.preferredColorScheme(.dark).environment(\.scenePhase, .active))
        window.makeKeyAndVisible(); defer { window.isHidden = true; window.rootViewController = nil }
        let ready = expectation(description: "Native tracker loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 4); window.layoutIfNeeded()
        XCTAssertGreaterThan(reads, 0); XCTAssertEqual(writes, 0)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "internet-tracker-two-providers-dark"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
