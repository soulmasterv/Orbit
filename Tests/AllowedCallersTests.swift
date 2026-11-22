import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor final class AllowedCallersTests: XCTestCase {
    private let fixture = Data(#"{"version":1,"availableModes":["jarvis","silly","bibo","diaa","diaa-noqta"],"callers":[{"number":"+201000000001","name":"Owner fixture","enabled":true,"modes":["jarvis","diaa"],"defaultMode":"jarvis"},{"number":"+201000000002","name":"Ahmed fixture","enabled":true,"modes":["silly","diaa","bibo"],"defaultMode":"silly","selectedMode":"diaa"},{"number":"+201000000003","name":"Disabled fixture","enabled":false,"modes":["diaa-noqta"],"defaultMode":"diaa-noqta"}]}"#.utf8)
    private func snapshot() throws -> OrbitAllowedCallers { try JSONDecoder().decode(OrbitAllowedCallers.self, from: fixture) }
    override func tearDown() async throws { MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil; MockURLProtocol.requests = [] }

    func testNumbersAcceptLocalInternationalAndFormattingRejectCommands() {
        for value in ["01000000001", "010 0000 0001", "+20 (100) 000-0001", "00201000000001", "201000000001"] {
            XCTAssertEqual(OrbitCallerNumber.normalized(value), "+201000000001")
        }
        XCTAssertEqual(OrbitCallerNumber.normalized("+442079460000"), "+442079460000")
        for value in ["", "0100000000", "01000000001,9", "+20abc", "201000000001@evil", "+000000000"] { XCTAssertNil(OrbitCallerNumber.normalized(value)) }
    }
    func testSelectedModeAndDefaultRemainDistinct() throws {
        let rows = try snapshot().callers
        XCTAssertNil(rows[0].selectedMode); XCTAssertEqual(rows[0].currentMode, "jarvis")
        XCTAssertEqual(rows[1].defaultMode, "silly"); XCTAssertEqual(rows[1].currentMode, "diaa")
        XCTAssertFalse(rows[2].enabled)
        XCTAssertEqual(OrbitIncomingMode.title("silly"), "Hossam")
        XCTAssertEqual(OrbitIncomingMode.title("bibo"), "Bibo feeding call")
    }
    func testDefaultFollowsAssignedModesAndNeverAllowsUnassignedChoice() throws {
        let value = try snapshot(); var draft = OrbitCallerDraft(value.callers[1])
        draft.assign("silly", enabled: false)
        XCTAssertEqual(draft.defaultMode, "bibo")
        draft.defaultMode = "diaa-noqta"
        XCTAssertNil(draft.change(available: value.availableModes, existing: value.callers))
        draft.assign("diaa", enabled: false); draft.assign("bibo", enabled: false)
        XCTAssertEqual(draft.defaultMode, "")
        XCTAssertNil(draft.change(available: value.availableModes, existing: value.callers))
    }
    func testGuestCannotAssignJarvisOwnerCannotDisableOrLosePrivateMode() throws {
        let value = try snapshot(); var guest = OrbitCallerDraft(value.callers[1])
        guest.assign("jarvis", enabled: true); XCTAssertFalse(guest.modes.contains("jarvis"))
        var owner = OrbitCallerDraft(value.callers[0]); owner.assign("jarvis", enabled: false)
        XCTAssertTrue(owner.modes.contains("jarvis"))
        owner.enabled = false; XCTAssertNil(owner.change(available: value.availableModes, existing: value.callers))
        var fresh = OrbitCallerDraft(); fresh.number = "01000000004"; fresh.modes = ["jarvis"]; fresh.defaultMode = "jarvis"
        XCTAssertNil(fresh.change(available: value.availableModes, existing: value.callers))
    }
    func testSavePayloadDoesNotContainSelectedModeOrResetAndDeleteIsMinimal() throws {
        let value = try snapshot(); var draft = OrbitCallerDraft(value.callers[1]); draft.name = "Edited fixture"
        let payload = try XCTUnwrap(draft.change(available: value.availableModes, existing: value.callers))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "save"); XCTAssertEqual(body["defaultMode"] as? String, "silly")
        XCTAssertNil(body["selectedMode"]); XCTAssertNil(body["reset"])
        let deletion = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OrbitCallerChange(action: "delete", number: value.callers[1].number))) as? [String: Any])
        XCTAssertEqual(Set(deletion.keys), ["action", "number"])
    }
    func testDuplicateAddAndChangingExistingNumberCannotCreateAccidentalCaller() throws {
        let value = try snapshot(); var draft = OrbitCallerDraft()
        draft.number = "01000000002"; draft.assign("diaa", enabled: true)
        XCTAssertNil(draft.change(available: value.availableModes, existing: value.callers))
        draft = OrbitCallerDraft(value.callers[1]); draft.number = "01000000004"
        XCTAssertNil(draft.change(available: value.availableModes, existing: value.callers))
    }
    func testUncertainSaveKeepsSnapshotAndRequiresRefreshBeforeAnotherPost() async throws {
        let state = OrbitAllowedCallersState(), value = try snapshot(); await state.load { value }
        var sends = 0
        let saved = await state.apply { sends += 1; throw URLError(.timedOut) }
        XCTAssertFalse(saved); XCTAssertEqual(state.snapshot?.callers[1].selectedMode, "diaa"); XCTAssertTrue(state.needsRefresh)
        _ = await state.apply { sends += 1; return value }; XCTAssertEqual(sends, 1)
        await state.load { value }; XCTAssertFalse(state.needsRefresh)
    }
    func testLockClearRejectsLateReadAndLateSave() async throws {
        let state = OrbitAllowedCallersState(), value = try snapshot()
        await state.load { state.clear(); return value }; XCTAssertNil(state.snapshot)
        await state.load { value }
        let saved = await state.apply { state.clear(); return value }
        XCTAssertFalse(saved); XCTAssertNil(state.snapshot); XCTAssertFalse(state.busy)
    }
    func testDoubleSubmissionAndUnknownVersionFailClosed() async throws {
        let state = OrbitAllowedCallersState(), value = try snapshot(); await state.load { value }
        var calls = 0
        _ = await state.apply {
            calls += 1
            _ = await state.apply { calls += 1; return value }
            return value
        }
        XCTAssertEqual(calls, 1)
        let wrong = OrbitAllowedCallers(version: 2, availableModes: [], callers: [])
        await state.load { wrong }; XCTAssertTrue(state.needsRefresh); XCTAssertEqual(state.snapshot?.version, 1)
    }

    private func api(_ defaults: UserDefaults, authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: configuration), defaults: defaults, tokenProvider: { "fixture-owner" }, authorize: authorize, phonePilotIsForeground: { true })
    }
    func testReadAndConfirmedSaveUseOnlyNewAuthenticatedEndpoint() async throws {
        let suite = "AllowedCallersTests.\(UUID())", data = fixture
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        var authorizations = 0; let api = api(defaults, authorize: { _ in authorizations += 1 })
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }; await api.loadDashboard()
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/jarvis/allowed-callers")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-owner")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            return (200, data)
        }
        _ = try await api.allowedCallers()
        let value = try snapshot(), change = try XCTUnwrap(OrbitCallerDraft(value.callers[1]).change(available: value.availableModes, existing: value.callers))
        let result = try await api.changeAllowedCaller(change)
        XCTAssertEqual(result.callers[1].selectedMode, "diaa"); XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(MockURLProtocol.requests.map(\.httpMethod), ["GET", "POST"])
    }
    func testLockDuringAuthorizationSendsNothing() async throws {
        let suite = "AllowedCallersTests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var instance: ServerAPI!; instance = api(defaults, authorize: { _ in instance.setAccessAllowed(false) })
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }; await instance.loadDashboard()
        MockURLProtocol.requests = []
        do { _ = try await instance.changeAllowedCaller(OrbitCallerChange(action: "delete", number: "+201000000002")); XCTFail() } catch { }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty); XCTAssertFalse(instance.actionBusy)
    }
    func testNativeListDetailsAndEditorLayoutsUseFixturesOnly() async throws {
        let suite = "AllowedCallersTests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = api(defaults), data = fixture, state = OrbitAllowedCallersState(), value = try snapshot()
        await state.load { value }
        MockURLProtocol.handler = { _ in (200, try JSONEncoder().encode(PreviewFixtures.dashboard)) }; await api.loadDashboard()
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in XCTAssertEqual(request.httpMethod, "GET"); return (200, data) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let screens: [(String, AnyView)] = [
            ("allowed-callers", AnyView(NavigationStack { OrbitAllowedCallersView(api: api) })),
            ("allowed-caller-details", AnyView(NavigationStack { OrbitAllowedCallerDetail(api: api, state: state, number: value.callers[1].number) })),
            ("allowed-caller-editor", AnyView(OrbitAllowedCallerEditor(api: api, state: state, initial: OrbitCallerDraft(value.callers[1]))))]
        for (name, content) in screens {
            let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: content.preferredColorScheme(.dark).environment(\.scenePhase, .active))
            window.makeKeyAndVisible(); let ready = expectation(description: name)
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { ready.fulfill() }; await fulfillment(of: [ready], timeout: 5)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }
}
