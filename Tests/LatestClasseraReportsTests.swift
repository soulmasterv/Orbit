import XCTest
@testable import Orbit

@MainActor
final class LatestClasseraReportsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "LatestClasseraReportsTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []
        MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil
        MockURLProtocol.onStart = nil
    }
    private func row(_ classID: String, available: Bool = true) -> [String: Any] {
        ["class_id": classID, "status": available ? "available" : "unavailable",
         "availability": "last_observed", "source": "log",
         "title": available ? "\(classID) 28/10" as Any : NSNull(),
         "classera_created_at": available ? "2026-10-28 14:14:42" as Any : NSNull(),
         "log_observed_at": available ? "2026-10-29 14:45:06.572" as Any : NSNull(),
         "timestamp_timezone": NSNull(), "attachment_id": NSNull(), "recorded_sent": NSNull()]
    }
    private func fixture(_ rows: [[String: Any]]? = nil, status: String = "available") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "status": status,
                                                    "results": rows ?? [row("12F"), row("12E")]])
    }
    private func decode(_ rows: [[String: Any]]? = nil, status: String = "available") throws -> LatestClasseraReportsResponse {
        try JSONDecoder().decode(LatestClasseraReportsResponse.self, from: fixture(rows, status: status))
    }
    private func api(token: String = "fixture-owner") -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
                         tokenProvider: { token }, authorize: { _ in XCTFail("Read-only refresh must not authorize a command") })
    }

    func testBothClassesDecodeHistoricalDatesAndNulls() throws {
        let value = try decode()
        XCTAssertTrue(value.isValid)
        XCTAssertEqual(value.observedCount, 2)
        XCTAssertEqual(Set(value.results.map(\.classID)), Set(["12F", "12E"]))
        for report in value.results {
            XCTAssertTrue(report.hasObservation)
            XCTAssertEqual(report.availability, "last_observed")
            XCTAssertEqual(report.source, "log")
            XCTAssertNil(report.attachmentID)
            XCTAssertNil(report.recordedSent)
            XCTAssertEqual(report.timezoneText, "Timezone not verified")
            XCTAssertEqual(report.createdText, "2026-10-28 14:14:42")
        }
    }
    func testMissingOptionalFieldsRemainUnknown() throws {
        let value = try decode([["class_id": "12F", "status": "available", "availability": "last_observed",
                                 "source": "log", "title": "12F 31/12/2025"]], status: "partial")
        XCTAssertTrue(value.isValid)
        XCTAssertEqual(value.observedCount, 1)
        XCTAssertNil(value.report(for: "12E"))
        let report = try XCTUnwrap(value.report(for: "12F"))
        XCTAssertEqual(report.createdText, "Not recorded")
        XCTAssertEqual(report.observedText, "Not recorded")
        XCTAssertNil(report.attachmentID)
        XCTAssertNil(report.recordedSent)
    }
    func testMissingResultsAndMissingTitleCannotProduceFakeObservations() throws {
        let noResults = try JSONDecoder().decode(LatestClasseraReportsResponse.self,
            from: Data(#"{"version":1,"status":"unavailable"}"#.utf8))
        XCTAssertEqual(noResults.observedCount, 0)
        let missing = try decode([["class_id": "12F", "status": "available"]], status: "partial")
        XCTAssertEqual(missing.observedCount, 0)
    }
    func testLiveAvailabilityUnknownSourceDuplicatesAndUnknownClassesRejected() throws {
        for change in [["availability": "live_available"], ["source": "api"], ["class_id": "12D"]] {
            var report = row("12F")
            for (key, value) in change { report[key] = value }
            XCTAssertFalse(try decode([report], status: "partial").isValid)
        }
        XCTAssertFalse(try decode([row("12F"), row("12F")]).isValid)
    }
    func testExplicitTimezoneIsDisplayedWithoutConversion() throws {
        var report = row("12F")
        report["timestamp_timezone"] = "Africa/Cairo"
        let value = try decode([report], status: "partial")
        XCTAssertEqual(value.results[0].timezoneText, "Recorded timezone: Africa/Cairo")
        XCTAssertEqual(value.results[0].createdText, "2026-10-28 14:14:42")
    }
    func testAuthenticatedClientUsesOnlyExistingOrbitGET() async throws {
        let data = try fixture()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://control.admin-ai.site/api/classera/latest-reports")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-owner")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            return (200, data)
        }
        let response = try await api().latestClasseraReports()
        XCTAssertEqual(response.observedCount, 2)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    func testPartial200AndUnavailable503Decode() async throws {
        for (http, rows, status, count) in [
            (200, [row("12F"), row("12E", available: false)], "partial", 1),
            (503, [row("12F", available: false), row("12E", available: false)], "unavailable", 0)
        ] {
            let data = try fixture(rows, status: status)
            MockURLProtocol.handler = { _ in (http, data) }
            let value = try await api().latestClasseraReports()
            XCTAssertEqual(value.status, status)
            XCTAssertEqual(value.observedCount, count)
        }
    }
    func testAuthenticationAndInvalidResponses() async throws {
        let valid = try fixture()
        for code in [401, 403] {
            MockURLProtocol.handler = { _ in (code, valid) }
            do { _ = try await api().latestClasseraReports(); XCTFail() }
            catch { XCTAssertEqual(error as? LatestClasseraReportsFailure, .authenticationRequired) }
        }
        for (code, data) in [(200, Data("invalid JSON".utf8)), (503, valid),
                             (200, Data(repeating: 32, count: 65_537))] {
            MockURLProtocol.handler = { _ in (code, data) }
            do { _ = try await api().latestClasseraReports(); XCTFail() }
            catch { XCTAssertEqual(error as? LatestClasseraReportsFailure, .invalidResponse) }
        }
    }
    func testMissingTokenAndLockedAppDoNotRequest() async {
        do { _ = try await api(token: "").latestClasseraReports(); XCTFail() } catch {}
        let locked = api(); locked.setAccessAllowed(false)
        do { _ = try await locked.latestClasseraReports(); XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testLockDuringRequestRejectsOldResponse() async throws {
        let data = try fixture()
        let server = api()
        MockURLProtocol.onStart = { request in
            Task { @MainActor in server.setAccessAllowed(false); request.respond(status: 200, data: data) }
        }
        do { _ = try await server.latestClasseraReports(); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testConnectionChangeInvalidatesOldReportContext() throws {
        let server = api()
        let original = server.latestReportsContext
        try server.saveConnection(url: "https://other.example.test", replacementToken: "")
        XCTAssertNotEqual(server.latestReportsContext, original)
    }
    func testStoreLoadingReadyPartialAndUnavailableStates() async throws {
        let store = LatestClasseraReportsStore()
        XCTAssertEqual(store.state, .idle)
        for (rows, status, expected) in [
            ([row("12F"), row("12E")], "available", LatestClasseraReportsState.ready),
            ([row("12F"), row("12E", available: false)], "partial", .partial),
            ([row("12F", available: false), row("12E", available: false)], "unavailable", .unavailable)
        ] {
            let response = try decode(rows, status: status)
            await store.load {
                XCTAssertEqual(store.state, .loading)
                XCTAssertNil(store.snapshot)
                return response
            }
            XCTAssertEqual(store.state, expected)
            XCTAssertFalse(store.loading)
        }
    }
    func testStoreAuthenticationNetworkAndCancellationStates() async throws {
        let store = LatestClasseraReportsStore()
        let value = try decode()
        await store.load { value }
        await store.load { throw LatestClasseraReportsFailure.authenticationRequired }
        XCTAssertEqual(store.state, .authenticationRequired)
        XCTAssertNil(store.snapshot)
        await store.load { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(store.state, .failed)
        XCTAssertNil(store.snapshot)
        await store.load { throw CancellationError() }
        XCTAssertEqual(store.state, .idle)
    }
    func testClearedStoreCannotRepublishInFlightData() async throws {
        let store = LatestClasseraReportsStore()
        let value = try decode()
        await store.load { store.clear(); return value }
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.state, .idle)
    }
    func testStateMessagesNeverClaimDeliveryOrLiveAvailability() {
        for state in [LatestClasseraReportsState.idle, .loading, .ready, .partial, .unavailable,
                      .authenticationRequired, .failed] {
            let message = state.message?.lowercased() ?? ""
            XCTAssertFalse(message.contains("live"))
            XCTAssertFalse(message.contains("delivered"))
            XCTAssertFalse(message.contains("sent"))
        }
    }
}
