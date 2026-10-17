import XCTest
import SwiftUI
import UIKit
@testable import ServerControl

@MainActor
final class MobileTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let connection = StudentsConnection(baseURL: "https://students.example", apiKey: "mock-students-key")
    private let phone = "201000000001"
    private var saved = MobileSecureState()
    nonisolated private static var capabilities: Data {
        Data(#"{"version":1,"onboarding_push":true,"feedback_push":true,"plain_text_messages":true,"message_idempotency":true,"automatic_reminders":false,"push":{"configured":false,"environment":"production","missing_settings":["APNS_KEY_ID"]}}"#.utf8)
    }
    nonisolated private static func rows(status: String? = "allowed", state: String = "active", open: Bool = true) -> Data {
        var row: [String: Any] = ["phone":"201000000001", "name":"Mock", "grade":"10", "state":state, "window_open":open, "seconds_left":open ? 5400 : 0]
        if let status { row["activity_status"] = status }
        return try! JSONSerialization.data(withJSONObject: [row])
    }
    nonisolated private static func result(id: UUID, status: String = "accepted") -> Data {
        try! JSONSerialization.data(withJSONObject: ["request_id":id.uuidString, "phone":"201000000001", "status":status,
            "created_at":1792070000, "updated_at":1792070001, "pricing":[:]] as [String: Any])
    }
    override func setUp() async throws {
        suite = "MobileTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        saved = MobileSecureState(); MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
        MockURLProtocol.handler = { request in
            switch request.url!.path {
            case "/api/mobile/capabilities": return (200, Self.capabilities)
            case "/api/events": return (200, Data("[]".utf8))
            case "/api/students": return (200, Self.rows())
            default:
                if request.httpMethod == "POST", let key = request.value(forHTTPHeaderField: "Idempotency-Key"), let id = UUID(uuidString: key) {
                    return (200, Self.result(id: id))
                }
                return (200, Data(#"{"ok":true}"#.utf8))
            }
        }
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults, tokenProvider: { "forbidden-bearer" }, authorize: authorize)
    }
    private func store(_ api: ServerAPI) -> MobileStore {
        MobileStore(api: api, load: { self.saved }, save: { next in
            if next.outbox != nil && self.saved.outbox == nil {
                XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" }, "UUID and draft must be durable BEFORE dispatch")
            }
            self.saved = next
        }, connection: { self.connection })
    }
    private func json(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCapabilitiesAuthenticatedAndReadinessSeparate() async {
        let store = store(api()); await store.refresh()
        XCTAssertTrue(store.capabilities?.supportsMessages == true)
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-API-Key") == "mock-students-key" && $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(MockURLProtocol.requests.last?.url?.query, "limit=50")
    }
    func testUnavailableCapabilitiesDoNotDispatch() async {
        MockURLProtocol.handler = { _ in (404, Data()) }
        let store = store(api()); await store.send(phone: phone, text: "Hello")
        XCTAssertNil(store.capabilities); XCTAssertNil(saved.outbox)
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    func testEligibilityRejectsUnknownRestrictedClosedAndIncomplete() async throws {
        for (status, state, open) in [(nil, "active", true), ("blocked", "active", true), ("suspended", "active", true), ("allowed", "awaiting_grade", true), ("allowed", "active", false)] as [(String?, String, Bool)] {
            let rows = Self.rows(status: status, state: state, open: open)
            let students = try JSONDecoder().decode([Student].self, from: rows)
            let snapshot = StudentsSnapshot(students: students, receivedAt: Date())
            XCTAssertFalse(MobileRules.canSend(students[0], snapshot: snapshot))
            MockURLProtocol.requests = []
            MockURLProtocol.handler = { request in
                if request.url?.path == "/api/mobile/capabilities" { return (200, Self.capabilities) }
                return (200, request.url?.path == "/api/events" ? Data("[]".utf8) : rows)
            }
            await store(api()).send(phone: phone, text: "Hello")
            XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
        }
    }
    func testSendPersistsBeforeOnePOSTAndUsesCorrectPayload() async throws {
        let entered = expectation(description: "Persisted before transport")
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/mobile/capabilities" { return (200, Self.capabilities) }
            if request.url?.path == "/api/events" { return (200, Data("[]".utf8)) }
            if request.url?.path == "/api/students" { return (200, Self.rows()) }
            let id = UUID(uuidString: request.value(forHTTPHeaderField: "Idempotency-Key")!)!
            // Persistence is asserted by the authorization-independent store below.
            entered.fulfill()
            return (200, Self.result(id: id))
        }
        let store = store(api()); await store.send(phone: phone, text: "  Hello  ")
        await fulfillment(of: [entered], timeout: 2)
        let request = try XCTUnwrap(MockURLProtocol.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(request.url?.path, "/api/students/\(phone)/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), connection.apiKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), saved.outbox?.requestID.uuidString)
        XCTAssertEqual(try json(request)["text"] as? String, "Hello")
        XCTAssertEqual(try json(request).count, 1)
        XCTAssertEqual(saved.outbox?.result?.status, "accepted")
        XCTAssertFalse(saved.outbox?.result?.explanation.contains("Delivery confirmed") == true)
        await store.send(phone: phone, text: "another")
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testPersistenceFailurePreventsPOST() async {
        let api = api()
        let store = MobileStore(api: api, load: { self.saved }, save: { state in
            if state.outbox != nil { throw APIError.message("Mock save failed") }
            self.saved = state
        }, connection: { self.connection })
        await store.send(phone: phone, text: "Hello")
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }
    func testDuplicateTapsAndLockDuringAuthorization() async {
        let entered = expectation(description: "Device authorization")
        var resume: CheckedContinuation<Void, Never>?
        let api = api(authorize: { _ in entered.fulfill(); await withCheckedContinuation { resume = $0 } })
        let store = store(api)
        let first = Task { await store.send(phone: self.phone, text: "Hello") }
        await fulfillment(of: [entered], timeout: 2)
        await store.send(phone: phone, text: "Duplicate")
        api.setAccessAllowed(false); store.suspend(); resume?.resume(); await first.value
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
        XCTAssertNil(saved.outbox)
    }
    func testTimeoutRestartRecoveryIsGETWithSameUUID() async throws {
        let original = MockURLProtocol.handler!
        MockURLProtocol.handler = { request in if request.httpMethod == "POST" { throw URLError(.timedOut) }; return try original(request) }
        let first = store(api()); await first.send(phone: phone, text: "Keep draft")
        let id = try XCTUnwrap(saved.outbox?.requestID)
        XCTAssertEqual(saved.outbox?.text, "Keep draft")
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/admin-messages/\(id.uuidString)")
            return (200, Self.result(id: id, status: "unknown"))
        }
        let restarted = store(api()); await restarted.recover()
        XCTAssertEqual(saved.outbox?.requestID, id)
        XCTAssertTrue(saved.outbox?.result?.needsReview == true)
        await restarted.send(phone: phone, text: "Must not resend")
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testMissingRecoveryNeverPermitsAutomaticSend() async {
        saved.outbox = PendingAdminMessage(requestID: UUID(), connection: connection, phone: phone, text: "Saved", attempted: true)
        MockURLProtocol.handler = { _ in (404, Data()) }
        let store = store(api()); await store.recover(); await store.send(phone: phone, text: "Retry")
        XCTAssertNotNil(saved.outbox); XCTAssertTrue(store.error != nil)
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    func testHTTP200ResultsAndPricingDoNotImplyDeliveryOrFree() throws {
        for status in ["pending", "accepted", "sent", "delivered", "read", "failed", "cancelled", "unknown", "future-status"] {
            let result = try JSONDecoder().decode(AdminMessage.self, from: Self.result(id: UUID(), status: status))
            XCTAssertEqual(result.status, status)
            XCTAssertEqual(result.pricing?.summary, "Pricing unknown")
            if !["delivered", "read"].contains(status) { XCTAssertFalse(result.explanation.hasPrefix("Delivery confirmed")) }
            if ["pending", "unknown", "future-status"].contains(status) { XCTAssertTrue(result.needsReview) }
        }
    }
    func testInvalidTextAndPhoneDoNotSendAndNoTemplateEndpoint() async {
        for text in ["  \n", String(repeating: "a", count: 3501)] { await store(api()).send(phone: phone, text: text) }
        await store(api()).send(phone: "../invalid", text: "Hello")
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.url!.path.contains("template") })
    }
    func testErrorsAreSanitizedAndNeverRetryPOST() async {
        for code in [401, 403, 404, 409, 422, 429, 500] {
            saved = MobileSecureState(); MockURLProtocol.requests = []
            let original = Self.capabilities
            MockURLProtocol.handler = { request in
                if request.url?.path == "/api/mobile/capabilities" { return (200, original) }
                if request.url?.path == "/api/events" { return (200, Data("[]".utf8)) }
                if request.httpMethod == "GET" { return (200, Self.rows()) }
                return (code, Data("private secret raw response".utf8))
            }
            let store = store(api()); await store.send(phone: phone, text: "Hello")
            XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
            XCTAssertFalse(store.error?.contains("private secret") == true)
            XCTAssertNotNil(saved.outbox)
        }
    }
    func testFailedRevocationBlocksConnectionChange() async {
        saved.registeredConnection = connection
        let store = store(api()); await store.refresh()
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { try await store.prepareConnectionChange(); XCTFail("Must retain old connection") } catch {}
        XCTAssertEqual(saved.registeredConnection, connection)
    }
    func testPendingConnectionRevocationPreventsNewSend() async throws {
        saved.registeredConnection = connection
        let store = store(api()); await store.refresh()
        let entered = expectation(description: "Revoking old destination")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in gate.capture(request); entered.fulfill() }
        let change = Task { try await store.prepareConnectionChange() }
        await fulfillment(of: [entered], timeout: 2)
        await store.send(phone: phone, text: "Must not race settings")
        XCTAssertNil(saved.outbox)
        gate.complete(with: Data(#"{"ok":true}"#.utf8))
        try await change.value
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }
    func testOldStudentsResponseRejectedAfterConnectionInvalidation() async {
        let api = api()
        let entered = expectation(description: "Old directory request")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in gate.capture(request); entered.fulfill() }
        let old = Task { try await api.fetchStudents(connection: self.connection) }
        await fulfillment(of: [entered], timeout: 2)
        api.invalidateStudentsConnection()
        gate.complete(with: Self.rows())
        do { _ = try await old.value; XCTFail("Old connection must not publish") } catch {}
    }
    func testDeletedEventAndFeedbackAreGraceful() async throws {
        let store = store(api()); await store.refresh()
        MockURLProtocol.handler = { _ in (404, Data()) }
        do { _ = try await store.event(UUID()); XCTFail("Missing event") } catch { XCTAssertTrue(MobileRules.error(error).contains("deleted")) }
        XCTAssertTrue(try FeedbackRecord.decode(Data("[]".utf8)).isEmpty)
        XCTAssertThrowsError(try FeedbackRecord.decode(Data(#"{"error":"private"}"#.utf8)))
    }
    func testFeedbackIntegerStatusFullListAndResolveReopen() async throws {
        let rows = Data(#"[{"id":12,"phone":"201000000001","note":"/wrong incorrect date","question":"Q","answer":"A","ts":1792070000,"resolved":0}]"#.utf8)
        let decoded = try FeedbackRecord.decode(rows)
        XCTAssertFalse(decoded[0].isResolved)
        XCTAssertEqual(decoded[0].date, Date(timeIntervalSince1970: 1792070000))
        let api = api()
        MockURLProtocol.handler = { request in (200, request.httpMethod == "GET" ? rows : Data(#"{"ok":true}"#.utf8)) }
        _ = try await api.fetchFeedback(connection: connection)
        XCTAssertEqual(MockURLProtocol.requests.last?.url?.query, "unresolved=false")
        for resolved in [true, false] {
            try await api.resolveFeedback(connection: connection, id: 12, resolved: resolved)
            let request = try XCTUnwrap(MockURLProtocol.requests.last)
            XCTAssertEqual(request.httpMethod, "PUT"); XCTAssertEqual(request.url?.path, "/api/feedback/12")
            XCTAssertEqual(try json(request)["resolved"] as? Bool, resolved)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { try await api.resolveFeedback(connection: connection, id: 12, resolved: true); XCTFail("Uncertain mutation") } catch {}
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testNotificationRetirementOnlyDeletesAndPreservesPendingSend() async throws {
        saved.pushEnabled = true; saved.registeredConnection = connection
        let pending = PendingAdminMessage(requestID: UUID(), connection: connection, phone: phone, text: "Keep this draft", attempted: true)
        saved.outbox = pending; saved.drafts[phone] = pending.text
        let mobile = store(api())
        await mobile.retireNotifications()
        XCTAssertFalse(saved.pushEnabled); XCTAssertNil(saved.registeredConnection)
        XCTAssertEqual(saved.outbox?.requestID, pending.requestID)
        XCTAssertEqual(saved.drafts[phone], pending.text)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "X-API-Key"), connection.apiKey)
        await mobile.retireNotifications()
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testRetirementFailureKeepsDestinationForCleanupWithoutEnablingPush() async {
        saved.pushEnabled = true; saved.registeredConnection = connection
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await store(api()).retireNotifications()
        XCTAssertFalse(saved.pushEnabled)
        XCTAssertEqual(saved.registeredConnection, connection)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.first?.httpMethod, "DELETE")
    }

    func testDirectoryFiltersPreserveOrderAndSeparateWindowFromReplyPermission() throws {
        let data = Data(#"[{"phone":"201000000003","name":"Sam Example","grade":"12","state":"active","activity_status":"suspended","window_open":true,"seconds_left":30},{"phone":"201000000002","name":"Lina Example","grade":"10","state":"active","activity_status":"allowed","window_open":false,"seconds_left":0},{"phone":"201000000001","name":null,"grade":null,"state":"awaiting_name","window_open":true,"seconds_left":120}]"#.utf8)
        let students = try JSONDecoder().decode([Student].self, from: data)
        let instant = ContinuousClock.now
        let snapshot = StudentsSnapshot(students: students, receivedAt: Date(), receivedInstant: instant)
        XCTAssertEqual(StudentsDirectory.filtered(snapshot, search: "", filter: .all, grade: "", at: instant).map(\.phone), students.map(\.phone))
        XCTAssertEqual(StudentsDirectory.filtered(snapshot, search: " sam ", filter: .open, grade: "", at: instant).map(\.phone), [students[0].phone])
        XCTAssertEqual(StudentsDirectory.filtered(snapshot, search: "0002", filter: .closed, grade: "", at: instant).count, 1)
        XCTAssertEqual(StudentsDirectory.filtered(snapshot, search: "", filter: .grade, grade: "12", at: instant).map(\.phone), [students[0].phone])
        XCTAssertEqual(StudentsDirectory.grades(in: students), ["10", "12"])
        XCTAssertEqual(StudentsDirectory.filtered(snapshot, search: "", filter: .open, grade: "", at: instant.advanced(by: .seconds(31))).map(\.phone), [students[2].phone])
        XCTAssertEqual(StudentsDirectory.countLabel(1), "1 student")
        XCTAssertEqual(StudentsDirectory.countLabel(0), "0 students")
    }

    func testStudentsLayoutSearchVisibleKeyboardDismissedAndDynamicType() async throws {
        let api = api()
        let students = try JSONDecoder().decode([Student].self, from: Data(#"[{"phone":"201000000001","name":"Sam Example","grade":"12","state":"active","activity_status":"allowed","window_open":true,"seconds_left":5400},{"phone":"201000000002","name":"Lina Example With A Longer Name","grade":"10","state":"active","activity_status":"suspended","window_open":false,"seconds_left":0}]"#.utf8))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func fields(in view: UIView) -> [UITextField] { (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) } }
        for (name, size) in [("standard", DynamicTypeSize.large), ("large-text", .accessibility1)] {
            for mode in [ColorScheme.dark, .light] {
                let studentsStore = StudentsStore(api: api, connectionProvider: { self.connection }, fetchSnapshot: { _ in StudentsSnapshot(students: students, receivedAt: Date()) })
                // A UIHostingController outside the app's Scene can inherit an
                // inactive phase. Seed the mocked snapshot before rendering so
                // these previews verify actual student cards, not an empty header.
                await studentsStore.refresh()
                XCTAssertEqual(studentsStore.snapshot?.students.count, 2)
                let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
                let root = NavigationStack { StudentsView(api: api, store: studentsStore) }
                    .environmentObject(store(api)).environment(\.dynamicTypeSize, size).preferredColorScheme(mode).tint(Brand.accent)
                window.rootViewController = UIHostingController(rootView: root)
                window.makeKeyAndVisible(); window.endEditing(true)
                let ready = expectation(description: "Students layout ready")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ready.fulfill() }
                await fulfillment(of: [ready], timeout: 5)
                window.layoutIfNeeded()
                XCTAssertEqual(studentsStore.snapshot?.students.count, 2)
                let searchField = try XCTUnwrap(fields(in: window).first { $0.placeholder == "Search name or phone" })
                XCTAssertFalse(searchField.isFirstResponder)
                let frame = searchField.convert(searchField.bounds, to: window)
                XCTAssertGreaterThan(frame.width, window.bounds.width * 0.65)
                XCTAssertLessThan(frame.minY, window.bounds.height * 0.45)
                XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, window.bounds.width)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "students-\(name)-\(mode == .dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
                window.isHidden = true
            }
        }
    }
}

