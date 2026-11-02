import XCTest
@testable import Orbit

@MainActor
final class OptOutRemovalAndGeminiMetadataTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        suite = "OptOutRemovalAndGeminiMetadataTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults, tokenProvider: { "owner-placeholder" }, authorize: authorize)
    }
    private func student(_ statuses: [String], signup: Bool = false) throws -> ClasseraStudent {
        let rows = statuses.enumerated().map { i, status -> [String: Any] in
            ["class_name": i == 0 ? "12F" : "12E", "name": "Fixture", "ai_enabled": 1, "status": status]
        }
        let object: [String: Any] = ["phone": "201000000001", "revision": String(repeating: "a", count: 64),
            "activity_status": "allowed", "subscriptions": rows, "signup_session": signup ? ["step": "class"] as Any : NSNull()]
        return try JSONDecoder().decode(ClasseraStudent.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testRemovalRequiresEveryClassOptedOutAndNoSignup() async throws {
        for states in [[], ["active"], ["paused"], ["opted_out", "active"], ["opted_out", "legacy_unknown"]] {
            let record = try student(states)
            do { _ = try await api().manageClasseraStudent(student: record, action: .remove); XCTFail() } catch {}
        }
        let onboarding = try student(["opted_out"], signup: true)
        XCTAssertFalse(onboarding.isOptedOut)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testOptOutDeletionUsesOneAuthenticatedDeleteAndInvalidatesDirectoryCache() async throws {
        let record = try student(["opted_out", "opted_out"]); let api = api(); var prompts = 0
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let server = ServerAPI(session: URLSession(configuration: config), defaults: defaults, tokenProvider: { "owner-placeholder" }, authorize: { _ in prompts += 1 })
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { return (200, Data(#"{"ok":true}"#.utf8)) }
            return (200, Data(#"{"gemini":[],"classera":[],"padel":[]}"#.utf8))
        }
        let result = try await server.manageClasseraStudent(student: record, action: .remove)
        XCTAssertNil(result); XCTAssertEqual(prompts, 1); XCTAssertEqual(server.classeraDirectoryRevision, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(request.url?.path, "/api/classera-students/201000000001")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "DELETE" }.count, 1)
        XCTAssertEqual(api.classeraDirectoryRevision, 0)
    }
    func testDeletionTimeoutIsUncertainAndNotRetried() async throws {
        let record = try student(["opted_out"])
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await api().manageClasseraStudent(student: record, action: .remove); XCTFail() }
        catch { XCTAssertEqual(error as? ClasseraDirectoryFailure, .uncertain) }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    func testSuccessfulDeletionForcesAutomaticDirectoryReadDespiteFreshSnapshot() async throws {
        let record = try student(["opted_out"]); let server = api(); let store = ClasseraDirectoryStore()
        let encoded = try JSONEncoder().encode(record)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let first = try JSONSerialization.data(withJSONObject: ["version": 1, "students": [object]])
        var deleted = false
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { deleted = true; return (200, Data(#"{"ok":true}"#.utf8)) }
            if request.url?.path == "/api/classera-students" { return (200, deleted ? Data(#"{"version":1,"students":[]}"#.utf8) : first) }
            return (200, Data(#"{"gemini":[],"classera":[],"padel":[]}"#.utf8))
        }
        await store.refresh(api: server, automatic: true); XCTAssertEqual(store.students.count, 1)
        _ = try await server.manageClasseraStudent(student: record, action: .remove)
        await store.refresh(api: server, automatic: true); XCTAssertTrue(store.students.isEmpty)
    }
    func testLegacyGeminiResponseStillDecodesAndSecretLikeTagsAreRejected() throws {
        let legacy = try JSONDecoder().decode(GeminiKeyStatus.self, from: Data(#"{"id":"key-1","name":"Gemini 1","status":"Working"}"#.utf8))
        XCTAssertNil(legacy.metadata)
        let malformed = try JSONDecoder().decode(GeminiKeyStatus.self, from: Data(#"{"id":"key-1","name":"Gemini 1","status":"Working","metadata":{"tag":7}}"#.utf8))
        XCTAssertEqual(malformed.status, "Working"); XCTAssertNil(malformed.metadata)
        let data = Data(#"{"tag":"School primary","project":"School","configured_for":["12F","12E"],"configuration_state":"verified","observed_in":["12F"],"usage_state":"ready","usage_days":30}"#.utf8)
        let value = try JSONDecoder().decode(GeminiKeyMetadata.self, from: data); XCTAssertTrue(value.isValid)
        let unsafe = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "School primary", with: "AIza-redacted-fixture")
        XCTAssertFalse(try JSONDecoder().decode(GeminiKeyMetadata.self, from: Data(unsafe.utf8)).isValid)
    }
}
