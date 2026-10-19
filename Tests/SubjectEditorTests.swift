import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class SubjectEditorTests: XCTestCase {
    private let phone = "201000000001"
    private let connection = StudentsConnection(baseURL: "https://students.example", apiKey: "subject-test-key")
    private var defaults: UserDefaults!
    private var suite: String!
    nonisolated private static let firstRevision = String(repeating: "r", count: 64)
    nonisolated private static let secondRevision = String(repeating: "s", count: 64)
    nonisolated private static var catalogData: Data {
        let ids = ["advanced_math", "statistics", "chemistry", "biology", "physics", "economics", "accounting", "computer_science_only", "computer_studies", "psychology"]
        let names = ["Advanced Math", "Statistics", "Advanced Chemistry", "Advanced Biology", "Advanced Physics", "Economics", "Accounting", "Computer Science", "Computer Studies", "Psychology"]
        func subject(_ id: String, _ name: String, _ compulsory: Bool) -> [String: Any] {
            ["id":id, "name":name, "compulsory":compulsory, "selectable":!compulsory, "reminder_eligible":true]
        }
        return try! JSONSerialization.data(withJSONObject: ["version":"subject-editor-v1",
            "compulsory_subjects":[subject("english", "English", true), subject("arabic", "Arabic", true), subject("religion", "Religion", true), subject("quraan", "Quraan", true)],
            "optional_subjects":zip(ids, names).map { subject($0.0, $0.1, false) },
            "choice_pairs":stride(from: 0, to: 10, by: 2).map { [ids[$0], ids[$0+1]] },
            "legacy_subjects":[["id":"computer_science", "name":"Computer Science / Studies"]]])
    }
    nonisolated private static func selectionData(_ optional: [String] = ["chemistry", "biology"], revision: String = firstRevision,
                                                 editable: Bool = true, legacy: [String] = ["computer_science"], unknown: [String] = ["old_unmapped_id"]) -> Data {
        let compulsory = ["english", "arabic", "religion"]
        return try! JSONSerialization.data(withJSONObject: ["phone":"201000000001", "revision":revision,
            "catalog_version":"subject-editor-v1", "editable":editable, "optional_subjects":optional,
            "compulsory_subjects":compulsory, "legacy_subject_ids":legacy, "unknown_subject_ids":unknown,
            "effective_subjects":compulsory + optional + legacy + unknown])
    }
    private func catalog() throws -> SubjectCatalog { try JSONDecoder().decode(SubjectCatalog.self, from: Self.catalogData).validated() }
    private func selection(_ data: Data? = nil) throws -> StudentSubjectSelection { try JSONDecoder().decode(StudentSubjectSelection.self, from: data ?? Self.selectionData()) }
    override func setUp() async throws {
        suite = "SubjectEditorTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/subjects/catalog" { return (200, Self.catalogData) }
            return (200, Self.selectionData())
        }
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api(authorize: @escaping (String) async throws -> Void = { _ in }) -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults, tokenProvider: { "must-not-be-forwarded" }, authorize: authorize)
    }
    private func store(_ api: ServerAPI) -> SubjectEditorStore {
        SubjectEditorStore(api: api, phone: phone, connectionProvider: { self.connection })
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

    func testCatalogHasTenDistinctOptionalIDsAndOnlyThreeDisplayedCompulsories() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.optionalSubjects.count, 10)
        XCTAssertEqual(catalog.optionalSubjects.first { $0.id == "computer_science_only" }?.name, "Computer Science")
        XCTAssertEqual(catalog.optionalSubjects.first { $0.id == "computer_studies" }?.name, "Computer Studies")
        XCTAssertFalse(catalog.optionalSubjects.contains { $0.id == "computer_science" })
        XCTAssertEqual(catalog.includedSubjects.map(\.id), ["english", "arabic", "religion"])
        XCTAssertFalse(catalog.includedSubjects.contains { $0.id == "quraan" })
        let value = try selection().validated(phone: phone, catalog: catalog)
        XCTAssertEqual(value.revision, Self.firstRevision)
        XCTAssertEqual(value.legacySubjectIDs, ["computer_science"])
        XCTAssertEqual(value.unknownSubjectIDs, ["old_unmapped_id"])
    }

    func testLiveEndpointGateLoadsBothBeforeAllowingEdits() async throws {
        let api = api(); let store = store(api)
        XCTAssertFalse(store.canEdit); XCTAssertFalse(store.canSave)
        let entered = expectation(description: "Student selections pending")
        let gate = DashboardRequestGate()
        MockURLProtocol.onStart = { request in
            if request.request.url?.path == "/api/subjects/catalog" { request.respond(status: 200, data: Self.catalogData) }
            else { gate.capture(request); entered.fulfill() }
        }
        let loading = Task { await store.load() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNotNil(store.catalog); XCTAssertFalse(store.canEdit); XCTAssertFalse(store.canSave)
        store.toggle("computer_studies"); await store.save()
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "PUT" })
        gate.complete(with: Self.selectionData()); await loading.value
        XCTAssertTrue(store.canEdit); XCTAssertFalse(store.canSave)
        store.toggle("computer_studies"); XCTAssertTrue(store.canSave)
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-API-Key") == connection.apiKey && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testUnavailableOrInvalidCatalogAndFailedSelectionsKeepSaveDisabled() async {
        for failure in ["catalog404", "catalog401", "badCatalog", "student404", "student401", "studentInvalid"] {
            MockURLProtocol.requests = []
            MockURLProtocol.handler = { request in
                if request.url?.path == "/api/subjects/catalog" {
                    if failure == "catalog404" { return (404, Data()) }
                    if failure == "catalog401" { return (401, Data()) }
                    if failure == "badCatalog" { return (200, Data("{}".utf8)) }
                    return (200, Self.catalogData)
                }
                if failure == "student404" { return (404, Data()) }
                if failure == "student401" { return (401, Data()) }
                return (200, Data("{}".utf8))
            }
            let store = store(api()); await store.load(); store.toggle("psychology"); await store.save()
            XCTAssertFalse(store.canEdit); XCTAssertFalse(store.canSave); XCTAssertNotNil(store.error, failure)
            XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testCheckboxesBatchOnePUTWithRevisionAndPreserveUnknownAndLegacy() async throws {
        let store = store(api()); await store.load()
        store.toggle("english"); store.toggle("quraan"); store.toggle("computer_science")
        XCTAssertEqual(store.selectedIDs, ["chemistry", "biology"])
        store.toggle("computer_science_only"); store.toggle("computer_studies"); store.toggle("biology")
        XCTAssertEqual(MockURLProtocol.requests.count, 2, "Editing checkboxes must not save")
        MockURLProtocol.handler = { _ in (200, Self.selectionData(["chemistry", "computer_science_only", "computer_studies"], revision: Self.secondRevision)) }
        await store.save()
        let put = try XCTUnwrap(MockURLProtocol.requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(put.url?.path, "/api/students/\(phone)/subjects")
        let payload = try body(put)
        XCTAssertEqual(payload.count, 3)
        XCTAssertEqual(payload["optional_subjects"] as? [String], ["chemistry", "computer_science_only", "computer_studies"])
        XCTAssertEqual(payload["expected_revision"] as? String, Self.firstRevision)
        XCTAssertEqual(payload["remove_legacy_subject_ids"] as? [String], [])
        XCTAssertEqual(store.selection?.revision, Self.secondRevision)
        XCTAssertEqual(store.selection?.legacySubjectIDs, ["computer_science"])
        XCTAssertEqual(store.selection?.unknownSubjectIDs, ["old_unmapped_id"])
        XCTAssertFalse(store.hasChanges); XCTAssertFalse(store.canSave)
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.url?.path.contains("/subjects") == true })
    }

    func testLegacyNeverSplitsAndRemovalRequiresSeparateExplicitSelection() async throws {
        let store = store(api()); await store.load()
        XCTAssertFalse(store.selectedIDs.contains("computer_science_only")); XCTAssertFalse(store.selectedIDs.contains("computer_studies"))
        store.toggle("computer_science_only"); store.toggle("computer_studies")
        XCTAssertFalse(store.removeCombined)
        store.setRemoveCombined(true)
        MockURLProtocol.handler = { _ in (200, Self.selectionData(["chemistry", "biology", "computer_science_only", "computer_studies"], revision: Self.secondRevision, legacy: [])) }
        await store.save()
        let put = try XCTUnwrap(MockURLProtocol.requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(try body(put)["remove_legacy_subject_ids"] as? [String], ["computer_science"])
        XCTAssertEqual(store.selection?.legacySubjectIDs, [])
        XCTAssertEqual(store.selection?.unknownSubjectIDs, ["old_unmapped_id"])
    }

    func testEmptyElectivesClearAndReadOnlyResponsesDisableAllChanges() async throws {
        let store = store(api()); await store.load()
        store.toggle("chemistry"); store.toggle("biology")
        MockURLProtocol.handler = { _ in (200, Self.selectionData([], revision: Self.secondRevision)) }
        await store.save()
        XCTAssertEqual(try body(XCTUnwrap(MockURLProtocol.requests.first { $0.httpMethod == "PUT" }))["optional_subjects"] as? [String], [])
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in (200, request.url?.path == "/api/subjects/catalog" ? Self.catalogData : Self.selectionData(editable: false)) }
        let readOnly = self.store(api()); await readOnly.load()
        readOnly.toggle("psychology"); readOnly.setRemoveCombined(true); await readOnly.save()
        XCTAssertFalse(readOnly.canEdit); XCTAssertFalse(readOnly.canSave); XCTAssertFalse(readOnly.removeCombined)
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testConflictLoadsLatestButRequiresReviewBeforeAnotherSave() async {
        let store = store(api()); await store.load(); store.toggle("psychology")
        MockURLProtocol.handler = { request in
            request.httpMethod == "PUT" ? (409, Data()) : (200, Self.selectionData(["physics"], revision: Self.secondRevision))
        }
        await store.save()
        XCTAssertTrue(store.needsReview); XCTAssertFalse(store.canSave); XCTAssertFalse(store.canEdit)
        XCTAssertTrue(store.selectedIDs.contains("psychology")); XCTAssertEqual(store.selection?.optionalSubjects, ["physics"])
        await store.save(); XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        store.useLatestChoices(); XCTAssertFalse(store.needsReview); XCTAssertEqual(store.selectedIDs, ["physics"])
        store.toggle("psychology"); XCTAssertTrue(store.canSave)
    }

    func testLostPUTResponseRecoversOnlyWithGETAndReplacesRevision() async {
        let store = store(api()); await store.load(); store.toggle("computer_studies")
        MockURLProtocol.handler = { request in
            if request.httpMethod == "PUT" { throw URLError(.timedOut) }
            return (200, Self.selectionData(["chemistry", "biology", "computer_studies"], revision: Self.secondRevision))
        }
        await store.save()
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(MockURLProtocol.requests.last?.httpMethod, "GET")
        XCTAssertEqual(store.selection?.revision, Self.secondRevision); XCTAssertFalse(store.hasChanges); XCTAssertTrue(store.verified)
    }

    func testUncertainResultCannotBeResavedUntilVerifiedAndReviewed() async {
        let store = store(api()); await store.load(); store.toggle("psychology")
        MockURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        await store.save(); XCTAssertFalse(store.verified); XCTAssertFalse(store.canSave)
        XCTAssertTrue(store.selectedIDs.contains("psychology"))
        await store.save(); XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        MockURLProtocol.handler = { request in (200, request.url?.path == "/api/subjects/catalog" ? Self.catalogData : Self.selectionData(["economics"], revision: Self.secondRevision)) }
        await store.load(); XCTAssertTrue(store.needsReview); XCTAssertFalse(store.canSave)
    }

    func testKnownHTTPFailuresAreClearAndNeverRetry() async {
        for code in [401, 403, 404, 422] {
            MockURLProtocol.requests = []
            MockURLProtocol.handler = { request in (200, request.url?.path == "/api/subjects/catalog" ? Self.catalogData : Self.selectionData()) }
            let store = store(api()); await store.load(); store.toggle("psychology")
            MockURLProtocol.handler = { _ in (code, Data("private raw error".utf8)) }
            await store.save()
            XCTAssertEqual(MockURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
            XCTAssertFalse(store.error?.contains("private raw error") == true)
            XCTAssertNotNil(store.error)
            if code != 422 { XCTAssertFalse(store.canSave) }
        }
    }

    func testDuplicateSaveAndBackgroundLockDuringAuthorization() async {
        let entered = expectation(description: "Authorizing subjects")
        var resume: CheckedContinuation<Void, Never>?
        let api = api(authorize: { _ in entered.fulfill(); await withCheckedContinuation { resume = $0 } })
        let store = store(api); await store.load(); store.toggle("psychology")
        let saving = Task { await store.save() }
        await fulfillment(of: [entered], timeout: 2)
        await store.save()
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "PUT" })
        api.setAccessAllowed(false); store.invalidate(); resume?.resume(); await saving.value
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "PUT" })
    }

    func testOlderRefreshCannotOverwriteNewerSavedChoices() async throws {
        let catalog = try catalog(); let initial = try selection()
        let updated = try selection(Self.selectionData(["psychology"], revision: Self.secondRevision))
        var calls = 0
        var release: CheckedContinuation<StudentSubjectSelection, Never>?
        let entered = expectation(description: "Old read pending")
        let api = api()
        let store = SubjectEditorStore(api: api, phone: phone, connectionProvider: { self.connection }, fetchCatalog: { _ in catalog }, fetchSelection: { _, _ in
            calls += 1
            if calls == 1 { entered.fulfill(); return await withCheckedContinuation { release = $0 } }
            return initial
        }, submit: { _, _, _ in updated })
        let old = Task { await store.load() }
        await fulfillment(of: [entered], timeout: 2)
        await store.load(); store.toggle("chemistry"); store.toggle("biology"); store.toggle("psychology"); await store.save()
        release?.resume(returning: initial); await old.value
        XCTAssertEqual(store.selection?.revision, Self.secondRevision)
        XCTAssertEqual(store.selectedIDs, ["psychology"])
    }

    func testConnectionChangesAndMalformedIdentifiersCannotSave() async {
        let api = api(); var configured = connection
        let store = SubjectEditorStore(api: api, phone: phone, connectionProvider: { configured })
        await store.load(); store.toggle("psychology")
        configured = StudentsConnection(baseURL: "https://other.example", apiKey: "another-test-key")
        await store.save(); XCTAssertFalse(store.verified)
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "PUT" })
        for invalid in ["+201000000001", "../subjects", ""] {
            do { _ = try await api.fetchStudentSubjects(connection: connection, phone: invalid); XCTFail("Invalid path") } catch {}
        }
    }

    func testSubjectEditorScreenshotsWithSelectedAndLegacySubjects() async throws {
        let api = api(); let store = store(api); await store.load()
        store.toggle("computer_science_only") // No save: preview the batched draft.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for mode in [ColorScheme.light, .dark] {
            let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: NavigationStack { SubjectEditorView(api: api, phone: phone, store: store) }.environment(\.scenePhase, .active).preferredColorScheme(mode).tint(Brand.accent))
            window.makeKeyAndVisible(); window.endEditing(true)
            let ready = expectation(description: "Subject editor layout")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 5)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "subject-editor-\(mode == .dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "PUT" })
    }
}
