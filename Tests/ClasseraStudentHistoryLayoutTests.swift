import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class ClasseraStudentHistoryLayoutTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        suite = "ClasseraStudentHistoryLayoutTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
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
    private func capture<Content: View>(_ name: String, content: Content) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack { content }
            .preferredColorScheme(.dark).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        let ready = expectation(description: name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 4); window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment); window.isHidden = true
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod != "GET" })
    }
    func testDirectoryFiltersAndSuspendedAtBottomLayout() async throws {
        func student(_ phone: String, _ name: String, _ status: String, _ activity: String) -> [String: Any] {
            ["phone": phone, "profile_name": name, "revision": String(repeating: "a", count: 64),
             "activity_status": activity, "signup_session": NSNull(),
             "subscriptions": [["class_name": "12F", "name": name, "status": status, "ai_enabled": 0]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "students": [
            student("201000000004", "Student D", "active", "suspended"),
            student("201000000001", "Student A", "active", "allowed"),
            student("201000000003", "Student C", "opted_out", "allowed")]])
        MockURLProtocol.handler = { _ in (200, data) }
        let api = api()
        try await capture("classera-directory-optout-filter-dark", content: ClasseraStudentsView(api: api))
        XCTAssertTrue(MockURLProtocol.requests.contains { $0.url?.path == "/api/classera-students" })
    }
    func testHistoryDetailDateTimeAndActualAIRequestLayout() async throws {
        let data = Data(#"{"id":"fixture","report":"12F 1/11/26","class_id":"12F","phone":"201000000001","student":"Student A","template":"classera_v9","message_id":"fixture-outbound","status":"read","created_at":1793536500,"updated_at":1793536860,"historical":false,"ai_analysis":{"status":"requested","requested_at":1793536980}}"#.utf8)
        let record = try JSONDecoder().decode(ClasseraDeliveryRecord.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data)
        let response = try JSONSerialization.data(withJSONObject: ["version": 1, "records": [object],
            "total": 1, "offset": 0, "next_offset": NSNull(), "updated_at": 1793536980, "limitations": []])
        MockURLProtocol.handler = { _ in (200, response) }
        let api = api()
        try await capture("classera-history-ai-request-dark", content: ClasseraDeliveryDetail(api: api, record: record))
        XCTAssertEqual(record.ai_analysis?.label, "Requested")
    }
}
