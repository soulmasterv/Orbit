import XCTest
@testable import ServerControl

@MainActor
final class StudentsManagementTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let connection = StudentsConnection(baseURL: "https://students.example", apiKey: "test-students-key")
    private let phone = "201000000001"

    nonisolated private static func rows(_ status: String? = "allowed") -> Data {
        var item: [String: Any] = ["phone": "201000000001", "name": "Test Student", "grade": "10",
                                   "state": "active", "window_open": true, "seconds_left": 5400]
        if let status { item["activity_status"] = status }
        return try! JSONSerialization.data(withJSONObject: [item])
    }
    override func setUp() async throws {
        suite = "StudentsManagementTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []
        MockURLProtocol.onStart = nil
        MockURLProtocol.handler = { _ in (200, Self.rows()) }
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.onStart = nil
        MockURLProtocol.handler = nil
    }
    private func makeAPI(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
                         tokenProvider: { "never-forward-this-bearer" }, authorize: authorize)
    }
    private func makeStore(_ api: ServerAPI) -> StudentsStore {
        StudentsStore(api: api, connectionProvider: { self.connection })
    }
    private func student(_ status: String?) throws -> Student {
        try XCTUnwrap(JSONDecoder().decode([Student].self, from: Self.rows(status)).first)
    }
    private func body(_ request: URLRequest) throws -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 512)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func testBackwardCompatibilityDoesNotImplyAllowed() async throws {
        for raw in [nil, "future-status", "", "allowed", "suspended", "blocked"] as [String?] {
            let decoded = try student(raw)
            XCTAssertEqual(decoded.activityStatus, raw.flatMap(StudentActivityStatus.init(rawValue:)) ?? .unknown)
        }
        let null = Data(#"[{"phone":"201000000001","name":null,"grade":null,"state":"awaiting_name","window_open":false,"seconds_left":0,"activity_status":null}]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([Student].self, from: null).first?.activityStatus, .unknown)
        let api = makeAPI()
        let store = makeStore(api)
        MockURLProtocol.handler = { _ in (200, Self.rows(nil)) }
        await store.refresh()
        let legacy = try XCTUnwrap(store.snapshot?.students.first)
        XCTAssertNotNil(store.managementUnavailableReason(for: legacy))
        for action in StudentManagementAction.allCases { _ = await store.manage(phone: phone, action: action) }
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testAllMutationMethodsPathsPayloadsAndDeviceAuthorization() async throws {
        var reasons: [String] = []
        let api = makeAPI(authorize: { reasons.append($0) })
        MockURLProtocol.handler = { _ in (200, Data(#"{"ok":true}"#.utf8)) }
        for action in StudentManagementAction.allCases {
            MockURLProtocol.requests = []
            try await api.mutateStudent(connection: connection, phone: phone, action: action)
            let request = try XCTUnwrap(MockURLProtocol.requests.first)
            XCTAssertEqual(MockURLProtocol.requests.count, 1)
            XCTAssertEqual(request.httpMethod, action == .remove ? "DELETE" : "PUT")
            XCTAssertEqual(request.url?.absoluteString, "https://students.example/api/students/\(phone)" + (action == .remove ? "" : "/activity"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "test-students-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if action == .remove {
                XCTAssertNil(request.httpBody)
                XCTAssertNil(request.httpBodyStream)
            } else {
                XCTAssertEqual(try body(request), ["activity_status": try XCTUnwrap(action.activityStatus?.rawValue)])
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            }
        }
        XCTAssertEqual(reasons.count, StudentManagementAction.allCases.count)
    }

    func testAuthorizationCancellationAndMalformedTargetsSendNothing() async {
        let api = makeAPI(authorize: { _ in throw CancellationError() })
        do { try await api.mutateStudent(connection: connection, phone: phone, action: .remove); XCTFail("Expected cancellation") } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        let other = makeAPI()
        for invalid in ["", "../api/process/1/stop", "+201000000001", "2010?key=secret", "٢٠١٠"] {
            do { try await other.mutateStudent(connection: connection, phone: invalid, action: .block); XCTFail("Invalid target") } catch {}
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testFailuresNeverRetryMutationAndRejectBadAcknowledgement() async {
        for failure in ["timeout", "lost", "401", "403", "500", "redirect", "invalid-json", "false", "204"] {
            let api = makeAPI()
            MockURLProtocol.requests = []
            MockURLProtocol.handler = { _ in
                switch failure {
                case "timeout": throw URLError(.timedOut)
                case "lost": throw URLError(.networkConnectionLost)
                case "401", "403", "500": return (Int(failure)!, Data(#"{"private":"must not display"}"#.utf8))
                case "redirect": return (302, Data())
                case "false": return (200, Data(#"{"ok":false}"#.utf8))
                case "204": return (204, Data())
                default: return (200, Data("raw private server response".utf8))
                }
            }
            do { try await api.mutateStudent(connection: connection, phone: phone, action: .block); XCTFail("Must not accept \(failure)") } catch {}
            XCTAssertEqual(MockURLProtocol.requests.count, 1, failure)
            XCTAssertFalse(api.actionBusy)
        }
        MockURLProtocol.requests = []
        let api = makeAPI()
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { try await api.mutateStudent(connection: connection, phone: phone, action: .remove); XCTFail("Expected uncertain delete") } catch {}
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "DELETE")
    }

    func testTimeoutRequiresSuccessfulVerificationBeforeAnotherAction() async throws {
        let api = makeAPI()
        let store = makeStore(api)
        await store.refresh()
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            if request.httpMethod == "PUT" { throw URLError(.timedOut) }
            throw URLError(.cannotConnectToHost)
        }
        let accepted = await store.manage(phone: phone, action: .block)
        XCTAssertFalse(accepted)
        XCTAssertTrue(store.actionError?.contains("may have succeeded") == true)
        XCTAssertTrue(store.requiresVerification)
        let count = MockURLProtocol.requests.count
        _ = await store.manage(phone: phone, action: .suspend)
        XCTAssertEqual(MockURLProtocol.requests.count, count)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        MockURLProtocol.handler = { _ in (200, Self.rows("blocked")) }
        await store.refresh()
        XCTAssertFalse(store.requiresVerification)
        XCTAssertEqual(store.snapshot?.students.first?.activityStatus, .blocked)
        XCTAssertNil(store.managementUnavailableReason(for: try XCTUnwrap(store.snapshot?.students.first)))
    }

    func testDuplicateActionsAndOrdinaryFaceIDInactivity() async throws {
        let entered = expectation(description: "Authorizing")
        var resume: CheckedContinuation<Void, Never>?
        let api = makeAPI(authorize: { _ in
            entered.fulfill()
            await withCheckedContinuation { resume = $0 }
        })
        let store = makeStore(api)
        await store.refresh()
        MockURLProtocol.handler = { request in
            request.httpMethod == "GET" ? (200, Self.rows("suspended")) : (200, Data(#"{"ok":true}"#.utf8))
        }
        let first = Task { await store.manage(phone: self.phone, action: .suspend) }
        await fulfillment(of: [entered], timeout: 2)
        let duplicate = await store.manage(phone: phone, action: .block)
        XCTAssertFalse(duplicate)
        store.suspend() // Face ID can make the scene inactive; it is not a background lock.
        resume?.resume()
        let succeeded = await first.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(store.snapshot?.students.first?.activityStatus, .suspended)
    }

    func testLockDuringAuthorizationPreventsMutation() async {
        let entered = expectation(description: "Authorizing")
        var resume: CheckedContinuation<Void, Never>?
        let api = makeAPI(authorize: { _ in entered.fulfill(); await withCheckedContinuation { resume = $0 } })
        let store = makeStore(api)
        await store.refresh()
        let task = Task { await store.manage(phone: self.phone, action: .remove) }
        await fulfillment(of: [entered], timeout: 2)
        api.setAccessAllowed(false)
        store.suspend(clear: true)
        resume?.resume()
        _ = await task.value
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertNil(store.snapshot)
    }

    func testOldInFlightRefreshCannotOverwriteMutationRefresh() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { _ in (200, Data(#"{"ok":true}"#.utf8)) }
        let oldRows = try JSONDecoder().decode([Student].self, from: Self.rows("allowed"))
        let newRows = try JSONDecoder().decode([Student].self, from: Self.rows("blocked"))
        var count = 0
        var releaseOld: CheckedContinuation<StudentsSnapshot, Never>?
        let pending = expectation(description: "Old refresh waiting")
        let store = StudentsStore(api: api, connectionProvider: { self.connection }, fetchSnapshot: { _ in
            count += 1
            if count == 2 {
                pending.fulfill()
                return await withCheckedContinuation { releaseOld = $0 } // Deliberately ignores cancellation.
            }
            return StudentsSnapshot(students: count == 1 ? oldRows : newRows, receivedAt: Date())
        })
        await store.refresh()
        let old = Task { await store.refresh() }
        await fulfillment(of: [pending], timeout: 2)
        let succeeded = await store.manage(phone: phone, action: .block)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.snapshot?.students.first?.activityStatus, .blocked)
        releaseOld?.resume(returning: StudentsSnapshot(students: oldRows, receivedAt: Date()))
        await old.value
        XCTAssertEqual(store.snapshot?.students.first?.activityStatus, .blocked)
        XCTAssertFalse(store.requiresVerification)
    }

    func testDeleteRemovesProfileEvenWhenVerificationFails() async throws {
        let api = makeAPI()
        let store = makeStore(api)
        await store.refresh()
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" { return (200, Data(#"{"ok":true}"#.utf8)) }
            throw URLError(.timedOut)
        }
        let removed = await store.manage(phone: phone, action: .remove)
        XCTAssertTrue(removed)
        XCTAssertTrue(store.snapshot?.students.isEmpty == true)
        XCTAssertTrue(store.requiresVerification)
        XCTAssertTrue(store.actionNotice?.contains("starts onboarding") == true)
    }

    func testVisibilityHandoffAndConnectionChangeDoNotAllowStaleCommands() async throws {
        let api = makeAPI()
        var configured = connection
        let store = StudentsStore(api: api, connectionProvider: { configured })
        let list = UUID(), detail = UUID()
        store.claimVisibility(list)
        await store.refresh()
        store.claimVisibility(detail)
        await store.refresh()
        store.suspend(owner: list) // The disappearing list must not cancel the visible detail.
        XCTAssertFalse(store.requiresVerification)
        configured = StudentsConnection(baseURL: "https://changed.example", apiKey: "different-test-key")
        MockURLProtocol.requests = []
        let changed = await store.manage(phone: phone, action: .block)
        XCTAssertFalse(changed)
        XCTAssertTrue(store.requiresVerification)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testUnsupportedMutationKeepsControlsDisabledAfterGET() async throws {
        for status in [404, 405, 501] {
            let store = makeStore(makeAPI())
            MockURLProtocol.handler = { request in
                request.httpMethod == "GET" ? (200, Self.rows()) : (status, Data())
            }
            await store.refresh()
            _ = await store.manage(phone: phone, action: .block)
            XCTAssertTrue(store.backendUnsupported)
            XCTAssertNotNil(store.managementUnavailableReason(for: try XCTUnwrap(store.snapshot?.students.first)))
        }
    }
}
