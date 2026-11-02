import XCTest
@testable import Orbit

@MainActor
final class ClasseraSubscriptionPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        suite = "ClasseraSubscriptionPolicyTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults, tokenProvider: { "owner-placeholder" }, authorize: authorize)
    }
    private func data(multiple: Bool = false, policy: Bool = true, enforced: Bool = true) throws -> Data {
        var value: [String: Any] = ["phone": "201000000001", "revision": String(repeating: "a", count: 64),
            "activity_status": "allowed", "subscriptions": [["class_name": "12F", "name": "Fixture", "ai_enabled": 1, "status": "active"]]]
        if policy {
            value["subscription_policy"] = ["version": 1, "enforced": enforced, "allow_multiple": multiple,
                "max_classes": multiple ? NSNull() as Any : 1, "occupied_classes": 1, "over_limit": false, "counted_statuses": ["active", "paused"]] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func student(multiple: Bool = false, policy: Bool = true, enforced: Bool = true) throws -> ClasseraStudent {
        try JSONDecoder().decode(ClasseraStudent.self, from: data(multiple: multiple, policy: policy, enforced: enforced))
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testLegacyResponseDecodesButCannotEnableOverride() async throws {
        let legacy = try student(policy: false); XCTAssertNil(legacy.subscriptionPolicy)
        do { _ = try await api().setClasseraSubscriptionOverride(student: legacy, allowMultiple: true); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testUnactivatedPolicyCannotSendAnOverride() async throws {
        let record = try student(enforced: false)
        XCTAssertTrue(record.subscriptionPolicy?.isValid == true)
        do { _ = try await api().setClasseraSubscriptionOverride(student: record, allowMultiple: true); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testMalformedPolicyKeepsExistingStudentButCannotAuthorizeOverride() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        object["subscription_policy"] = ["version": 1, "enforced": "yes"]
        let record = try JSONDecoder().decode(ClasseraStudent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(record.phone, "201000000001"); XCTAssertEqual(record.subscriptions.count, 1)
        XCTAssertNil(record.subscriptionPolicy)
        do { _ = try await api().setClasseraSubscriptionOverride(student: record, allowMultiple: true); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testOwnerPutUsesExactPathRevisionAndBooleanWithoutStudentAPIKey() async throws {
        let record = try student(); let response = try data(multiple: true); var prompts = 0
        MockURLProtocol.handler = { _ in (200, response) }
        let result = try await api(authorize: { _ in prompts += 1 }).setClasseraSubscriptionOverride(student: record, allowMultiple: true)
        XCTAssertTrue(result.subscriptionPolicy?.allowMultiple == true); XCTAssertEqual(prompts, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first); XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "PUT"); XCTAssertEqual(request.url?.path, "/api/classera-students/201000000001/subscription-policy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
        let payload = try body(request); XCTAssertEqual(Set(payload.keys), ["expected_revision", "allow_multiple"])
        XCTAssertEqual(payload["expected_revision"] as? String, record.revision); XCTAssertEqual(payload["allow_multiple"] as? Bool, true)
    }
    func testTimeoutNeverRetriesAndHasUncertainOutcome() async throws {
        let record = try student(); MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await api().setClasseraSubscriptionOverride(student: record, allowMultiple: true); XCTFail() }
        catch { XCTAssertEqual(error as? ClasseraDirectoryFailure, .uncertain) }
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    func testConflictAndAuthenticationFailureNeverExposeRawResponsesOrRetry() async throws {
        let record = try student()
        for status in [401, 409] {
            MockURLProtocol.requests = []; MockURLProtocol.handler = { _ in (status, Data("raw-private-fixture".utf8)) }
            do { _ = try await api().setClasseraSubscriptionOverride(student: record, allowMultiple: true); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.contains("raw-private-fixture")); if status == 409 { XCTAssertEqual(error as? ClasseraDirectoryFailure, .conflict) } }
            XCTAssertEqual(MockURLProtocol.requests.count, 1)
        }
    }
    func testAdministratorCannotRemoveOrInventStudentOptOut() async throws {
        let record = try student(); var prompts = 0
        XCTAssertThrowsError(try ClasseraStudentEdit(student: record, rows: []))
        var rows = record.subscriptions; rows[0].status = "opted_out"
        XCTAssertThrowsError(try ClasseraStudentEdit(student: record, rows: rows))
        do { _ = try await api(authorize: { _ in prompts += 1 }).manageClasseraStudent(student: record, action: .remove); XCTFail() } catch {}
        XCTAssertEqual(prompts, 0); XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testPermissionCancellationSendsNothing() async throws {
        let record = try student()
        do { _ = try await api(authorize: { _ in throw CancellationError() }).setClasseraSubscriptionOverride(student: record, allowMultiple: true); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
}
