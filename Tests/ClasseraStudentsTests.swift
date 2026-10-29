import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class ClasseraStudentsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var record: Data { Data("""
    {"phone":"201000000001","activity_status":"allowed","revision":"\(String(repeating: "a", count: 64))","signup_session":null,"subscriptions":[{"phone":"201000000001","class_name":"12F","name":"Test Student","ai_enabled":null,"status":"active","joined_at":"old","updated_at":"now"},{"class_name":"LEGACY","name":"Legacy","ai_enabled":0,"status":"active"}]}
    """.utf8) }
    override func setUp() async throws {
        suite = "ClasseraStudentsTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil }
    private func api(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults, tokenProvider: { "owner-placeholder" }, authorize: authorize)
    }
    func testDecodingPreservesClassSpecificPreferencesAndLegacy() throws {
        let student = try JSONDecoder().decode(ClasseraStudent.self, from: record)
        XCTAssertNil(student.subscriptions.first?.aiEnabled)
        XCTAssertEqual(student.subscriptions.first?.joinedAt,"old")
        XCTAssertFalse(student.subscriptions[1].editable)
        let data = try JSONEncoder().encode(ClasseraStudentEdit(student: student, rows: student.subscriptions))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(json["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(rows.count,1); XCTAssertTrue(rows[0]["ai_enabled"] is NSNull)
        XCTAssertNil(rows[0]["joined_at"]); XCTAssertNil(rows[0]["phone"])
        XCTAssertEqual(ClasseraClass.title("classera-1"),"Classera 1 (F)")
        XCTAssertEqual(ClasseraClass.title("12E"),"Classera 2 (E)")
    }
    func testClasseraWindowIsOptionalAndNeverInferredFromSubscriptionDates() throws {
        let legacy = try JSONDecoder().decode(ClasseraStudent.self, from: record)
        XCTAssertNil(legacy.whatsappWindows)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        json["whatsapp_windows"] = [
            ["class_name": "12F", "window_open": true, "seconds_left": 5400, "last_inbound_at": 1793010000],
            ["class_name": "12E", "window_open": false, "seconds_left": 0, "last_inbound_at": 1792900000]
        ]
        let student = try JSONDecoder().decode(ClasseraStudent.self, from: JSONSerialization.data(withJSONObject: json))
        let start = ContinuousClock.now
        let open = try XCTUnwrap(student.whatsappWindows?.first)
        XCTAssertEqual(open.label(since: start, at: start), "Open · 01:30")
        XCTAssertEqual(open.remainingSeconds(since: start, at: start.advanced(by: .seconds(60))), 5340)
        XCTAssertEqual(open.label(since: start, at: start.advanced(by: .seconds(5400))), "Closed")
        XCTAssertEqual(student.whatsappWindows?.last?.label(since: start, at: start), "Closed")
        // Activity/AI preferences are separate; window data never enables an action.
        XCTAssertEqual(student.activityStatus, legacy.activityStatus)
        XCTAssertEqual(student.subscriptions, legacy.subscriptions)
    }
    func testClasseraWindowInvalidOrUnverifiedDataIsUnavailable() {
        let start = ContinuousClock.now
        for item in [
            ClasseraWhatsAppWindow(className: "12F", windowOpen: nil, secondsLeft: nil, lastInboundAt: nil),
            ClasseraWhatsAppWindow(className: "12F", windowOpen: true, secondsLeft: 86401, lastInboundAt: 1793010000),
            ClasseraWhatsAppWindow(className: "12F", windowOpen: true, secondsLeft: -1, lastInboundAt: 1793010000),
            ClasseraWhatsAppWindow(className: "12F", windowOpen: false, secondsLeft: 30, lastInboundAt: 1793010000)
        ] {
            XCTAssertNil(item.remainingSeconds(since: start, at: start))
            XCTAssertEqual(item.label(since: start, at: start), "Unknown")
        }
    }
    func testWaitingSubscriptionNeverDisplaysEnabledAIPreference() {
        let row = ClasseraSubscription(className: "12E", name: "Student", aiEnabled: 1, status: "waiting_for_class")
        XCTAssertEqual(ClasseraSubscriptionSummary.aiLabel(row), "Not set")
        XCTAssertEqual(ClasseraSubscriptionSummary.aiLabel(ClasseraSubscription(className: "12F", name: "Student", aiEnabled: 1, status: "active")), "On")
    }
    func testOwnerCredentialOnlyOnOrbitOriginAndNoStudentKey() async throws {
        let data = record
        MockURLProtocol.handler = { _ in (200,data) }
        let student = try await api().loadClasseraStudent(phone:"201000000001")
        XCTAssertEqual(student.phone,"201000000001")
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.host,"control.admin-ai.site")
        XCTAssertEqual(request.url?.path,"/api/classera-students/201000000001")
        XCTAssertEqual(request.httpMethod,"GET")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer owner-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField:"X-API-Key"))
    }
    func testSaveOnePutWithRevisionAndNoMessageOrRetry() async throws {
        let student = try JSONDecoder().decode(ClasseraStudent.self,from:record)
        let renamed = try ClasseraNameEdit.applying("  Updated Student  ", to: student.subscriptions)
        let payload = try ClasseraStudentEdit(student:student,rows:renamed)
        let data = record
        MockURLProtocol.handler = { request in
            if request.httpMethod == "PUT" { return (200,data) }
            return (200,Data(#"{"gemini":[],"classera":[],"padel":[]}"#.utf8))
        }
        var auth = 0
        _ = try await api(authorize: { _ in auth += 1 }).saveClasseraStudent(phone:student.phone,payload:payload)
        XCTAssertEqual(auth,1)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count,1)
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path,"/api/classera-students/201000000001")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Content-Type"),"application/json")
        let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            return data
        })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sentRows = try XCTUnwrap(json["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(sentRows.first?["name"] as? String, "Updated Student")
        XCTAssertEqual(json["expected_revision"] as? String, student.revision)
    }
    func testRenamePreservesClassesPreferencesStatusesAndLegacyNames() throws {
        let student = try JSONDecoder().decode(ClasseraStudent.self, from: record)
        var rows = student.subscriptions
        rows.append(ClasseraSubscription(className: "12E", name: "Other name", aiEnabled: nil, status: "waiting_for_class"))
        let renamed = try ClasseraNameEdit.applying("  أحمد علي  ", to: rows)
        XCTAssertEqual(renamed.map(\.name), ["أحمد علي", "Legacy", "أحمد علي"])
        for index in rows.indices {
            XCTAssertEqual(renamed[index].className, rows[index].className)
            XCTAssertEqual(renamed[index].aiEnabled, rows[index].aiEnabled)
            XCTAssertEqual(renamed[index].status, rows[index].status)
            XCTAssertEqual(renamed[index].joinedAt, rows[index].joinedAt)
        }
        for invalid in ["", "   ", String(repeating: "x", count: 121), "Student\u{0000}Name"] {
            XCTAssertThrowsError(try ClasseraNameEdit.applying(invalid, to: rows))
        }
        XCTAssertThrowsError(try ClasseraNameEdit.applying("Valid", to: []))
        XCTAssertThrowsError(try ClasseraNameEdit.applying("Valid", to: rows.filter { !$0.editable }))
    }
    func testPendingClassIsNotInferredFromAllowedActivityOrActiveSubscriptions() throws {
        let student = try JSONDecoder().decode(ClasseraStudent.self, from: record)
        XCTAssertFalse(student.hasPendingClass)
        let pending = String(decoding: record, as: UTF8.self).replacingOccurrences(of: "\"status\":\"active\"", with: "\"status\":\"waiting_for_class\"")
        XCTAssertTrue(try JSONDecoder().decode(ClasseraStudent.self, from: Data(pending.utf8)).hasPendingClass)
    }
    func testTimeoutAndConflictNeverRepeatMutation() async throws {
        let student = try JSONDecoder().decode(ClasseraStudent.self,from:record)
        let payload = try ClasseraStudentEdit(student:student,rows:[])
        for status in [0,409,401,422] {
            MockURLProtocol.requests = []
            MockURLProtocol.handler = { _ in if status == 0 { throw URLError(.timedOut) }; return (status,Data()) }
            do { _ = try await api().saveClasseraStudent(phone:student.phone,payload:payload); XCTFail() }
            catch {
                if status == 0 { XCTAssertEqual(error as? ClasseraDirectoryFailure,.uncertain) }
                if status == 409 { XCTAssertEqual(error as? ClasseraDirectoryFailure,.conflict) }
            }
            XCTAssertEqual(MockURLProtocol.requests.count,1)
        }
    }
    func testValidationCancelledAuthorizationAndLockedNoRequest() async throws {
        let student = try JSONDecoder().decode(ClasseraStudent.self,from:record)
        var rows = student.subscriptions
        rows[0].name = " "
        XCTAssertThrowsError(try ClasseraStudentEdit(student:student,rows:rows))
        XCTAssertFalse(ClasseraPhone.valid("+201000000001")); XCTAssertFalse(ClasseraPhone.valid("abc"))
        XCTAssertTrue(ClasseraPhone.valid(student.phone))
        let payload = try ClasseraStudentEdit(student:student,rows:[])
        do { _ = try await api(authorize:{ _ in throw CancellationError() }).saveClasseraStudent(phone:student.phone,payload:payload); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        let locked=api(); locked.setAccessAllowed(false)
        do { _ = try await locked.loadClasseraStudent(phone:student.phone); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testLockDuringAuthorizationCannotSend() async throws {
        let student=try JSONDecoder().decode(ClasseraStudent.self,from:record)
        let payload=try ClasseraStudentEdit(student:student,rows:[])
        var server: ServerAPI!
        server=api(authorize:{ _ in server.setAccessAllowed(false) })
        do { _ = try await server.saveClasseraStudent(phone:student.phone,payload:payload); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testManagementPutDeleteAndNoMutationRetry() async throws {
        let student = try JSONDecoder().decode(ClasseraStudent.self, from: record)
        for action in [StudentManagementAction.block, .suspend, .remove] {
            MockURLProtocol.requests = []
            MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
            do { _ = try await api().manageClasseraStudent(student: student, action: action); XCTFail() }
            catch { XCTAssertEqual(error as? ClasseraDirectoryFailure, .uncertain) }
            let request = try XCTUnwrap(MockURLProtocol.requests.first)
            XCTAssertEqual(MockURLProtocol.requests.count, 1)
            XCTAssertEqual(request.httpMethod, action == .remove ? "DELETE" : "PUT")
            XCTAssertEqual(request.url?.path, "/api/classera-students/201000000001" + (action == .remove ? "" : "/activity"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
        }
        let payload = ClasseraManagementPayload(expectedRevision: student.revision, activityStatus: "blocked")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(json["activity_status"] as? String, "blocked")
        XCTAssertEqual(json["expected_revision"] as? String, student.revision)
    }

    func testResumeLegacyClasseraRestrictionUsesExistingDeviceAuthorization() async throws {
        let legacy = String(decoding: record, as: UTF8.self).replacingOccurrences(of: "\"activity_status\":\"allowed\"", with: "\"activity_status\":\"blocked\"")
        let student = try JSONDecoder().decode(ClasseraStudent.self, from: Data(legacy.utf8))
        let data = record
        var authorizations = 0
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/activity") == true { return (200, data) }
            return (200, Data(#"{"gemini":[],"classera":[],"padel":[]}"#.utf8))
        }
        let result = try await api(authorize: { _ in authorizations += 1 }).manageClasseraStudent(student: student, action: .resume)
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(result?.activityStatus, .allowed)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/classera-students/201000000001/activity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
    }
    func testStudentWorkspaceAndClasseraDirectoryIPhoneLayouts() async throws {
        let data = record
        let names = ["Omar Hassan", "Ahmed Ali", "Sara Mahmoud", "Nour Ahmed", "Youssef Adel", "Mariam Tarek With A Longer Name"]
        let statuses = ["allowed", "suspended", "allowed", "blocked", "allowed", "allowed"]
        let examples: [[String: Any]] = try names.enumerated().map { index, name in
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            value["phone"] = index == 5 ? "201000000006123" : String(format: "20100000000%d", index + 1)
            value["activity_status"] = statuses[index]
            value["subscriptions"] = [["class_name": index.isMultiple(of: 2) ? "12F" : "12E", "name": name, "ai_enabled": 1, "status": "active"]]
            if index == 4 {
                value["signup_session"] = ["step": "class", "name": name]
                value["subscriptions"] = [["class_name": "12D", "name": name, "status": "waiting_for_class", "ai_enabled": NSNull()]]
            }
            return value
        }
        let directoryData = try JSONSerialization.data(withJSONObject: ["version": 1, "students": examples])
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/classera-students" {
                return (200, directoryData)
            }
            return (200,data)
        }
        let server = api()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let views: [(String, AnyView)] = [
            ("student-databases", AnyView(NavigationStack { StudentDatabasesView(api: server) })),
            ("classera-subscribers", AnyView(NavigationStack { ClasseraStudentsView(api: server) })),
            ("student-databases-large-text", AnyView(NavigationStack { StudentDatabasesView(api: server) }.environment(\.dynamicTypeSize, .accessibility1))),
            ("classera-student-controls", AnyView(NavigationStack { ClasseraStudentEditor(api: server, phone: "201000000001") }))]
        for (name, view) in views {
            let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: view.preferredColorScheme(.dark).environment(\.scenePhase, .active))
            window.makeKeyAndVisible(); window.endEditing(true)
            let laidOut = expectation(description: "Layout \(name)")
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { laidOut.fulfill() }
            await fulfillment(of: [laidOut], timeout: 5)
            window.layoutIfNeeded()
            XCTAssertTrue(MockURLProtocol.requests.contains { $0.url?.path == (name == "classera-student-controls" ? "/api/classera-students/201000000001" : "/api/classera-students") })
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }
    func testGroupedClasseraStudentDetailsWithWindowIPhoneLayouts() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        json["subscriptions"] = [
            ["class_name": "12F", "name": "Ahmed Ali", "ai_enabled": 1, "status": "active"],
            ["class_name": "12E", "name": "Ahmed Ali", "ai_enabled": NSNull(), "status": "waiting_for_class"]
        ]
        json["whatsapp_windows"] = [
            ["class_name": "12F", "window_open": true, "seconds_left": 5400, "last_inbound_at": 1793010000],
            ["class_name": "12E", "window_open": false, "seconds_left": 0, "last_inbound_at": 1792900000]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let windows = try JSONSerialization.data(withJSONObject: ["version": 1, "phone": "201000000001",
            "whatsapp_windows": json["whatsapp_windows"]!])
        MockURLProtocol.handler = { request in
            (200, request.url?.path.hasSuffix("/messaging") == true ? windows : data)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for large in [false, true] {
            let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                ClasseraStudentEditor(api: api(), phone: "201000000001")
            }.preferredColorScheme(.dark).environment(\.scenePhase, .active)
                .environment(\.dynamicTypeSize, large ? .accessibility1 : .large))
            window.makeKeyAndVisible(); window.endEditing(true)
            let ready = expectation(description: "Student details loaded")
            DispatchQueue.main.asyncAfter(deadline: .now()+1.5) { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 5)
            window.layoutIfNeeded()
            for lower in [false, true] {
                if lower, let scroll = detailsScroll(window.rootViewController!.view) {
                    scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height-scroll.bounds.height)), animated: false)
                    window.layoutIfNeeded()
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "classera-grouped-\(large ? "large-text" : "standard")-\(lower ? "management" : "profile")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
            window.isHidden = true
        }
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    private func detailsScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
        for child in view.subviews { if let found = detailsScroll(child) { return found } }
        return nil
    }

}




