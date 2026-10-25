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
        let payload = try ClasseraStudentEdit(student:student,rows:student.subscriptions)
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
    func testStudentWorkspaceAndClasseraDirectoryIPhoneLayouts() async throws {
        let data = record
        let names = ["Omar Hassan", "Ahmed Ali", "Sara Mahmoud", "Nour Ahmed", "Youssef Adel", "Mariam Tarek With A Longer Name"]
        let statuses = ["allowed", "suspended", "allowed", "blocked", "allowed", "allowed"]
        let examples: [[String: Any]] = try names.enumerated().map { index, name in
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            value["phone"] = index == 5 ? "201000000006123" : String(format: "20100000000%d", index + 1)
            value["activity_status"] = statuses[index]
            value["subscriptions"] = [["class_name": index.isMultiple(of: 2) ? "12F" : "12E", "name": name, "ai_enabled": 1, "status": "active"]]
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
}

