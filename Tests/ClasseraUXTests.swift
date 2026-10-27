import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class ClasseraUXTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var student: Data {
        Data("""
        {"phone":"201000000001","profile_name":"Student","activity_status":"allowed","signup_session":null,
        "revision":"\(String(repeating:"a",count:64))","subscriptions":[{"class_name":"12F","name":"Student","ai_enabled":1,"status":"active"}]}
        """.utf8)
    }
    override func setUp() async throws {
        suite = "ClasseraUXTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
            tokenProvider: { "owner-placeholder" }, authorize: authorize)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testDisabledFaceIDIsUnlockedBeforeFirstRender() async {
        defaults.set(false, forKey: "appLock.v4")
        var prompts = 0
        let session = AppSession(defaults: defaults, authenticate: { prompts += 1 })
        XCTAssertTrue(session.isUnlocked)
        await session.activate()
        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(prompts, 0)
    }
    func testGeminiAdditionalKeyCanBeTestedOnlyWhenServerPermits() async throws {
        let status = Data(#"{"gemini":[{"id":"key-12","name":"Gemini 12","status":"Working","canTest":true}],"classera":[],"padel":[]}"#.utf8)
        let server = api()
        let dashboard = try JSONEncoder().encode(PreviewFixtures.dashboard)
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/dashboard" { return (200, dashboard) }
            if request.httpMethod == "POST" { return (200, Data(#"{"ok":true}"#.utf8)) }
            return (200, status)
        }
        await server.loadDashboard()
        XCTAssertTrue(server.canControl)
        await server.loadServices()
        await server.serviceAction(ServiceCommand(kind: .testGeminiKey, id: "key-12", name: "Gemini 12"))
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.first { $0.httpMethod == "POST" }?.url?.path, "/api/services/gemini/key-12/test")
        await server.serviceAction(ServiceCommand(kind: .testGeminiKey, id: "key-13", name: "Gemini 13"))
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testEgyptianPhoneNormalization() {
        XCTAssertEqual(ClasseraPhone.normalized("01011288486"), "201011288486")
        XCTAssertEqual(ClasseraPhone.normalized(" 201011288486 "), "201011288486")
        for value in ["", "01abc", "0101128848", "+201011288486", "00012345678"] {
            XCTAssertNil(ClasseraPhone.normalized(value))
        }
    }
    func testSubscriptionThreeModesAndLegacyPendingPreservation() throws {
        let original = ClasseraSubscription(className: "12F", name: "Name", aiEnabled: nil, status: "waiting_for_class", joinedAt: "old")
        XCTAssertNil(ClasseraSubscriptionMode.current(original))
        for mode in ClasseraSubscriptionMode.allCases {
            let result = mode.applying(to: original)
            XCTAssertEqual(ClasseraSubscriptionMode.current(result), mode)
            XCTAssertEqual(result.name, original.name); XCTAssertEqual(result.joinedAt, original.joinedAt)
            if mode == .disabled { XCTAssertEqual(result.status, "disabled"); XCTAssertNil(result.aiEnabled) }
            else { XCTAssertEqual(result.status, "active") }
        }
        let record = try JSONDecoder().decode(ClasseraStudent.self, from: student)
        _ = try ClasseraStudentEdit(student: record, rows: [ClasseraSubscriptionMode.disabled.applying(to: original)])
    }
    func testFaceIDSessionLastsFiveMinutesWithoutRenewingOnAppSwitch() async {
        var clock: TimeInterval = 0; var prompts = 0
        let session = AppSession(defaults: defaults, uptime: { clock }, authenticate: { prompts += 1 })
        await session.activate(); XCTAssertTrue(session.isUnlocked); XCTAssertEqual(prompts, 1)
        clock = 120; await session.activate(); XCTAssertEqual(prompts, 1); XCTAssertTrue(session.isUnlocked)
        clock = 299; session.expireIfNeeded(); XCTAssertTrue(session.isUnlocked)
        clock = 300; session.expireIfNeeded(); XCTAssertFalse(session.isUnlocked)
        await session.activate(); XCTAssertTrue(session.isUnlocked); XCTAssertEqual(prompts, 2)
        XCTAssertEqual(session.remainingUnlockTime, 300)
    }
    func testCreateProfileAndImmediateRenameUseSeparateAuthenticatedRequests() async throws {
        let data = student; var auth = 0
        MockURLProtocol.handler = { _ in (200, data) }
        let server = api(authorize: { _ in auth += 1 })
        let created = try await server.createClasseraProfile(phone: "201000000001", name: "Student")
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.requests.first?.url?.path, "/api/classera-students")
        let create = try body(MockURLProtocol.requests[0])
        XCTAssertEqual(Set(create.keys), ["phone", "name"])
        _ = try await server.renameClasseraStudent(student: created, name: "Renamed")
        let request = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT"); XCTAssertTrue(request.url!.path.hasSuffix("/name"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertEqual(Set(try body(request).keys), ["name", "expected_revision"])
        XCTAssertEqual(auth, 2)
    }
    func testPlaintextUsesOnePOSTWithConfirmationPersistenceAndNoRetry() async throws {
        let payload = ClasseraTextPayload(requestID: UUID().uuidString.lowercased(), className: "12F", text: "Test fixture only")
        var auth = 0; var saved = 0
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await api(authorize: { _ in auth += 1 }).sendClasseraText(phone: "201000000001", payload: payload) { saved += 1 }
            XCTFail()
        } catch { XCTAssertEqual(error as? ClasseraDirectoryFailure, .uncertain) }
        XCTAssertEqual(auth, 1); XCTAssertEqual(saved, 1); XCTAssertEqual(MockURLProtocol.requests.count, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/classera-students/201000000001/messaging")
        XCTAssertEqual(try body(request)["text"] as? String, payload.text)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
    }
    func testPlaintextAuthorizationCancellationAndPersistenceFailureDoNotSend() async {
        let payload = ClasseraTextPayload(requestID: UUID().uuidString.lowercased(), className: "12F", text: "Fixture")
        for denied in [false, true] {
            let server = api(authorize: { _ in if denied { throw CancellationError() } })
            do { _ = try await server.sendClasseraText(phone: "201000000001", payload: payload) { throw APIError.message("Storage unavailable") }; XCTFail() }
            catch {}
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testClosedWindowIsDefiniteRejectionAndOperationRecoveryIsReadOnly() async throws {
        let payload = ClasseraTextPayload(requestID: UUID().uuidString.lowercased(), className: "12F", text: "Fixture")
        MockURLProtocol.handler = { _ in (409, Data(#"{"error":"window_closed"}"#.utf8)) }
        do { _ = try await api().sendClasseraText(phone: "201000000001", payload: payload) {}; XCTFail() }
        catch { XCTAssertEqual((error as? ClasseraTextRejection)?.code, "window_closed") }
        MockURLProtocol.requests = []
        let result = Data("""
        {"version":1,"id":"\(payload.requestID)","phone":"201000000001","status":"unknown","message_id":null}
        """.utf8)
        MockURLProtocol.handler = { _ in (200, result) }
        let operation = try await api().classeraTextStatus(phone: "201000000001", id: payload.requestID)
        XCTAssertEqual(operation.status, "unknown")
        XCTAssertEqual(MockURLProtocol.requests.count, 1); XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "GET")
    }
}
