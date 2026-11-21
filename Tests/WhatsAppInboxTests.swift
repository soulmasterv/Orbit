import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class WhatsAppInboxTests: XCTestCase {
    func testRecipientFormattingAndInvalidCharacters() {
        for input in ["010 0000 0001", "+20 (100) 000-0001", "00201000000001"] { XCTAssertEqual(OrbitWhatsAppPhone.normalized(input), "201000000001") }
        XCTAssertNil(OrbitWhatsAppPhone.normalized("201000000001@evil"))
    }
    func testUnknownSendBlocksSecondTapAndNeverRetriesAutomatically() async {
        let state = OrbitWhatsAppSubmission()
        var calls = 0
        await state.submit(phone: "201000000001", text: "Fixture") { _ in calls += 1; throw URLError(.timedOut) }
        let first = state.pending?.request_id
        await state.submit(phone: "201000000001", text: "Fixture") { _ in calls += 1; throw URLError(.timedOut) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(state.pending?.request_id, first)
        XCTAssertNotNil(state.notice)
    }
    func testCheckUsesOriginalIDAndConfirmedSentReleasesComposer() async {
        let state = OrbitWhatsAppSubmission()
        await state.submit(phone: "201000000001", text: "Fixture") { _ in throw URLError(.timedOut) }
        let id = state.pending?.request_id
        await state.check { requestID in
            XCTAssertEqual(requestID, id)
            return OrbitWhatsAppResult(status: "sent", request_id: requestID, message_id: "fixture")
        }
        XCTAssertNil(state.pending)
        XCTAssertFalse(state.busy)
    }
    func testLockClearDiscardsLateSensitiveSendState() async {
        let state = OrbitWhatsAppSubmission()
        await state.submit(phone: "201000000001", text: "Fixture") { _ in
            state.clear()
            throw URLError(.networkConnectionLost)
        }
        XCTAssertNil(state.pending)
        XCTAssertNil(state.notice)
    }
    func testMismatchedOrMissingSendReceiptCannotConfirmAnotherRequest() async {
        let state = OrbitWhatsAppSubmission()
        await state.submit(phone: "201000000001", text: "Fixture") { _ in
            OrbitWhatsAppResult(status: "sent", request_id: UUID().uuidString, message_id: "other")
        }
        XCTAssertNotNil(state.pending)
        let id = state.pending?.request_id
        await state.check { _ in OrbitWhatsAppResult(status: "sent", request_id: id, message_id: nil) }
        XCTAssertNotNil(state.pending)
    }
    func testMissingReadStatusNeverDecodesAsRead() throws {
        let data = Data(#"{"connected":true,"messages":[{"id":"fixture","chat":"201000000001","text":"Fixture","outgoing":true,"at":1700000000,"status":"unknown"}]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(OrbitWhatsAppMessages.self, from: data).messages[0].status, "unknown")
    }
    func testInboxAndConversationNativeLayoutsUseOnlyFixtureEndpoints() async throws {
        let suite = "WhatsAppInboxTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        let api = ServerAPI(session: URLSession(configuration: configuration), defaults: defaults, tokenProvider: { "fixture-owner" }, authorize: { _ in })
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-owner")
            if request.url?.path == "/api/jarvis/whatsapp" {
                return (200, Data(#"{"connected":true,"chats":[{"id":"201000000001","name":"Ahmed","latest":"See you tomorrow.","at":1700000000,"unread":2}]}"#.utf8))
            }
            if request.url?.path.hasSuffix("/read") == true { return (200, Data(#"{"status":"ok"}"#.utf8)) }
            return (200, Data(#"{"connected":true,"messages":[{"id":"one","chat":"201000000001","text":"Are we meeting tomorrow?","outgoing":false,"at":1700000000,"status":"received"},{"id":"two","chat":"201000000001","text":"Yes, see you tomorrow.","outgoing":true,"at":1700000001,"status":"delivered"},{"id":"three","chat":"201000000001","text":"Class notes","outgoing":true,"at":1700000002,"status":"sent","media":{"id":"11111111-1111-4111-8111-111111111111","kind":"document","name":"Class notes.pdf","mime":"application/pdf","size":245760,"state":"available"}}]}"#.utf8))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, content) in [("whatsapp-inbox", AnyView(OrbitWhatsAppInboxView(api: api))), ("whatsapp-chat", AnyView(OrbitWhatsAppChatView(api: api, phone: "201000000001", name: "Ahmed")))] {
            let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: NavigationStack { content }.preferredColorScheme(.dark).environment(\.scenePhase, .active))
            window.makeKeyAndVisible()
            let ready = expectation(description: name); DispatchQueue.main.asyncAfter(deadline: .now()+1) { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 5)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.url?.path.hasSuffix("/send") == true })
    }
}
