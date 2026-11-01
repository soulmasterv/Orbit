import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class ClasseraReportSettingsTests: XCTestCase {
    private let suite = "Orbit.ReportSettingsTests"
    private var defaults: UserDefaults!
    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
        MockURLProtocol.handler = { _ in XCTFail("No live request is permitted"); throw URLError(.cancelled) }
    }
    override func tearDown() async throws {
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
        defaults.removePersistentDomain(forName: suite)
    }
    private func api(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
            tokenProvider: { "owner-fixture" }, authorize: authorize)
    }
    private func settings(_ classID: String = "classera-1", revision: String = String(repeating: "a", count: 64), ai: Int = 1, noAI: Int = 1) -> [String: Any] {
        ["version": 1, "class_id": classID, "class_name": classID == "classera-1" ? "12F" : "12E",
         "revision": revision, "capabilities": ["bulk_ai": true, "next_notice": false],
         "counts": ["eligible": ai + noAI, "ai": ai, "no_ai": noAI, "preserved": 3]]
    }
    private func data(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func preview() -> Data {
        var value = settings(); value["ai_enabled"] = 0; value["affected_count"] = 1
        return data(value)
    }
    private func result(id: String, cancelled: Bool = false) -> Data {
        data(["version": 1, "request_id": id, "class_id": "classera-1", "kind": cancelled ? "cancelled" : "bulk-ai",
              "status": cancelled ? "cancelled" : "completed", "affected_count": cancelled ? 0 : 1,
              "settings": settings(revision: String(repeating: "b", count: 64), ai: cancelled ? 1 : 0, noAI: cancelled ? 1 : 2)])
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        if let bytes = request.httpBody { return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]) }
        let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    func testRequestMethodsPathsPayloadOwnerAuthAndSingleAuthorization() async throws {
        var authorizations = 0; var persisted = false
        let api = api(authorize: { _ in authorizations += 1 })
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            let path = request.url!.path
            if path.hasSuffix("/bulk-ai/preview") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(try self.body(request)["ai_enabled"] as? Int, 0)
                return (200, self.preview())
            }
            if path.hasSuffix("/bulk-ai/operations") {
                XCTAssertTrue(persisted); XCTAssertEqual(request.httpMethod, "POST")
                let body = try self.body(request)
                XCTAssertEqual(Set(body.keys), ["request_id", "expected_revision", "ai_enabled", "expected_affected_count"])
                XCTAssertEqual(body["expected_affected_count"] as? Int, 1)
                return (200, self.result(id: try XCTUnwrap(body["request_id"] as? String)))
            }
            XCTAssertEqual(path, "/api/classera/report-settings/classera-1")
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, self.data(self.settings()))
        }
        _ = try await api.classeraReportSettings("classera-1")
        let preview = try await api.classeraBulkAIPreview("classera-1", value: 0)
        _ = try await api.applyClasseraBulkAI("classera-1", payload: ClasseraBulkAIPayload(preview)) { persisted = true }
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(MockURLProtocol.requests.count, 3)
    }
    func testBackwardCompatibilityMissingEndpointAndNoticeCapabilityGate() async {
        let api = api(); let store = ClasseraReportSettingsStore(loadPending: { nil }, savePending: { _ in })
        MockURLProtocol.handler = { _ in (404, Data(#"{"detail":"private server body"}"#.utf8)) }
        await store.refresh(api: api, classID: "classera-1")
        XCTAssertNil(store.settings); XCTAssertFalse(store.canMutate)
        XCTAssertTrue(store.error?.contains("not installed") == true)
        XCTAssertFalse(store.error?.contains("private") == true)
        MockURLProtocol.handler = { _ in (200, self.data(self.settings())) }
        await store.refresh(api: api, classID: "classera-1")
        XCTAssertFalse(store.settings!.capabilities.next_notice)
        store.setDraft("Fixture")
        await store.saveNotice(api: api, confirmedText: "Fixture", revision: store.settings!.revision)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }
    func testNoticePutContainsOneNoticeAndRevisionWithNoMutationRetry() async throws {
        let api = api(); let id = UUID().uuidString.lowercased(); var persisted = false
        MockURLProtocol.handler = { request in
            XCTAssertTrue(persisted)
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/classera/report-settings/classera-2/next-notice")
            let body = try self.body(request)
            XCTAssertEqual(Set(body.keys), ["request_id", "expected_revision", "text"])
            XCTAssertEqual(body["text"] as? String, "Fixture notice")
            return (200, self.data(["version": 1, "request_id": id, "class_id": "classera-2", "kind": "next-notice", "status": "completed", "affected_count": 0, "settings": self.settings("classera-2")]))
        }
        _ = try await api.saveClasseraReportNotice("classera-2", payload: ClasseraNoticePayload(request_id: id, expected_revision: String(repeating: "a", count: 64), text: "Fixture notice")) { persisted = true }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    func testTimeoutUsesOneMutationThenGetRecoveryAndFreshSnapshot() async throws {
        let api = api(); var saved: ClasseraReportPending?; var submittedID = ""; var recovered = false
        let store = ClasseraReportSettingsStore(loadPending: { saved }, savePending: { saved = $0 })
        MockURLProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/preview") { return (200, self.preview()) }
            if path.hasSuffix("/bulk-ai/operations") {
                submittedID = try XCTUnwrap(try self.body(request)["request_id"] as? String)
                XCTAssertEqual(saved?.request_id, submittedID)
                throw URLError(.timedOut)
            }
            if path.contains("/operations/") { recovered = true; XCTAssertEqual(request.httpMethod, "GET"); return (200, self.result(id: submittedID)) }
            return (200, self.data(self.settings(revision: String(repeating: recovered ? "b" : "a", count: 64), ai: recovered ? 0 : 1, noAI: recovered ? 2 : 1)))
        }
        await store.refresh(api: api, classID: "classera-1"); await store.prepareAI(api: api, value: 0)
        await store.applyAI(api: api, confirmed: try XCTUnwrap(store.preview))
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.url!.path.hasSuffix("/bulk-ai/operations") }.count, 1)
        XCTAssertNil(store.pending); XCTAssertNil(saved); XCTAssertNil(store.error)
        XCTAssertEqual(store.settings?.counts.no_ai, 2)
    }
    func testUnknownOutcomeStaysBlockedUntilExplicitServerCancellation() async throws {
        let api = api(); var saved: ClasseraReportPending?; var submittedID = ""
        let store = ClasseraReportSettingsStore(loadPending: { saved }, savePending: { saved = $0 })
        MockURLProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/preview") { return (200, self.preview()) }
            if path.hasSuffix("/bulk-ai/operations") { submittedID = try XCTUnwrap(try self.body(request)["request_id"] as? String); throw URLError(.timedOut) }
            if path.hasSuffix("/cancel") { XCTAssertEqual(request.httpMethod, "POST"); XCTAssertTrue(try self.body(request).isEmpty); return (200, self.result(id: submittedID, cancelled: true)) }
            if path.contains("/operations/") { return (404, Data("{}".utf8)) }
            return (200, self.data(self.settings()))
        }
        await store.refresh(api: api, classID: "classera-1"); await store.prepareAI(api: api, value: 0)
        await store.applyAI(api: api, confirmed: try XCTUnwrap(store.preview))
        XCTAssertNotNil(store.pending); XCTAssertFalse(store.canMutate)
        await store.prepareAI(api: api, value: 1)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.url!.path.hasSuffix("/preview") }.count, 1)
        await store.checkPending(api: api, cancel: true)
        XCTAssertNil(store.pending); XCTAssertNil(saved); XCTAssertTrue(store.canMutate)
    }
    func testConflictRefreshesAndRequiresNewPreviewWithoutRetry() async throws {
        let api = api(); var saved: ClasseraReportPending?; var conflict = false
        let store = ClasseraReportSettingsStore(loadPending: { saved }, savePending: { saved = $0 })
        MockURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/preview") { return (200, self.preview()) }
            if request.url!.path.hasSuffix("/bulk-ai/operations") { conflict = true; return (409, Data("{}".utf8)) }
            return (200, self.data(self.settings(revision: String(repeating: conflict ? "b" : "a", count: 64))))
        }
        await store.refresh(api: api, classID: "classera-1"); await store.prepareAI(api: api, value: 0)
        await store.applyAI(api: api, confirmed: try XCTUnwrap(store.preview))
        XCTAssertNil(saved); XCTAssertNil(store.preview)
        XCTAssertTrue(store.error?.contains("Review") == true)
        XCTAssertEqual(store.settings?.revision, String(repeating: "b", count: 64))
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.url!.path.hasSuffix("/bulk-ai/operations") }.count, 1)
    }
    func testAuthorizationAndVaultFailurePreventSubmission() async throws {
        let cancelledAPI = api(authorize: { _ in throw CancellationError() })
        let value = try JSONDecoder().decode(ClasseraAIPreview.self, from: preview())
        do { _ = try await cancelledAPI.applyClasseraBulkAI("classera-1", payload: ClasseraBulkAIPayload(value)) { XCTFail("Cannot persist before authorization") }; XCTFail("Expected cancellation") } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        let store = ClasseraReportSettingsStore(loadPending: { throw APIError.message("fixture") }, savePending: { _ in XCTFail("Cannot save") })
        await store.refresh(api: api(), classID: "classera-1")
        XCTAssertFalse(store.canMutate); XCTAssertFalse(store.vaultReady)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testClearPreventsAnInFlightRefreshRestoringPrivateState() async {
        let api = api(); let store = ClasseraReportSettingsStore(loadPending: { nil }, savePending: { _ in })
        let started = expectation(description: "request started")
        MockURLProtocol.onStart = { _ in started.fulfill() }
        MockURLProtocol.handler = { _ in Thread.sleep(forTimeInterval: 0.15); return (200, self.data(self.settings())) }
        let task = Task { await store.refresh(api: api, classID: "classera-1") }
        await fulfillment(of: [started], timeout: 2)
        store.clear(); api.setAccessAllowed(false)
        await task.value
        XCTAssertNil(store.settings); XCTAssertFalse(store.loading); XCTAssertFalse(store.canMutate)
    }
    func testReportSettingsIPhoneLayout() async throws {
        MockURLProtocol.handler = { _ in (200, self.data(self.settings())) }
        let api = api(); let store = ClasseraReportSettingsStore(loadPending: { nil }, savePending: { _ in })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ClasseraReportSettingsView(api: api, store: store)
        }.preferredColorScheme(.dark).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        let ready = expectation(description: "layout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 4); window.layoutIfNeeded()
        XCTAssertNotNil(store.settings)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "classera-report-settings-dark"; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.url!.path.hasSuffix("/bulk-ai/operations") })
    }
}
