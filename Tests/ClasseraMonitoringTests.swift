import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class ClasseraMonitoringTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let counts = #"{"reserved":0,"accepted":0,"sent":0,"delivered":1,"read":0,"failed":0,"unknown":0}"#
    override func setUp() async throws {
        suite = "ClasseraMonitoringTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
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
    private func preview(_ enabled: Bool = false) -> Data {
        Data("""
        {"version":1,"class_id":"12F","class_name":"Classera 1 (F)","supported":true,"revision":"\(String(repeating:"a",count:64))","eligible_count":1,"waiting_count":1,"can_execute":\(enabled),"disabled_reason":\(enabled ? "null" : "\"template_contract_unverified\""),"students":[{"phone":"201000000001","name":"Sample Student","joined_at":"2026-10-01T10:00:00+03:00","notification_status":"not_notified","eligible":true}],"updated_at":1793010000}
        """.utf8)
    }
    private func waiting() -> Data {
        Data("""
        {"version":1,"classes":[\(String(decoding:preview(),as:UTF8.self))],"updated_at":1793010000,"sending_enabled":false,"notice":"Notifications invite students to opt in. They do not enable a scheduler."}
        """.utf8)
    }
    private func history(_ title: String = "Daily report") -> Data {
        Data("""
        {"version":1,"records":[{"id":"fixture-1","report":"\(title)","report_date":"2026-10-26","class_id":"12F","phone":"201000000001","student":"Sample Student","template":null,"message_id":"mock-message","status":"delivered","created_at":null,"updated_at":1793010000,"historical":true}],"total":1,"offset":0,"next_offset":null,"updated_at":1793010000,"limitations":["Legacy templates and expected recipients were not recorded."]}
        """.utf8)
    }
    private func statistics() -> Data {
        Data("""
        {"version":1,"from":"2026-10-20","to":"2026-10-26","updated_at":1793010000,"reports":[{"id":"row","date":"2026-10-26","class_id":"12F","report":"Daily report","counts":\(counts),"attempts":1,"expected":null,"delivered_targets":null,"not_attempted":null,"skipped":null,"delivery_rate":null}],"counts":\(counts),"attempts":1,"expected":null,"delivered_targets":null,"not_attempted":null,"skipped":null,"delivery_rate":null,"unknown_date_records":0,"limitations":["Historical delivery rates are unavailable without expected-recipient snapshots."]}
        """.utf8)
    }
    private func operation(_ id: String) -> Data {
        Data("""
        {"version":1,"request_id":"\(id)","class_id":"12F","status":"complete","created_at":1793010000,"updated_at":1793010001,"total":1,"counts":{"reserved":0,"accepted":1,"sent":0,"delivered":0,"read":0,"failed":0,"unknown":0},"recipients":[{"phone":"201000000001","status":"accepted","error_code":null}]}
        """.utf8)
    }
    func testReadOnlyRoutesOwnerCredentialAndURLQueryEncoding() async throws {
        let data = history()
        MockURLProtocol.handler = { _ in (200,data) }
        _ = try await api().classeraDeliveryHistory(["search":"A&B", "class_id":"12F","offset":"30","limit":"30","sort":"updated"])
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod,"GET")
        XCTAssertEqual(request.url?.host,"control.admin-ai.site")
        XCTAssertEqual(request.url?.path,"/api/classera/delivery-history")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer owner-placeholder")
        XCTAssertNil(request.value(forHTTPHeaderField:"X-API-Key"))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where:{$0.name=="search"})?.value,"A&B")
        XCTAssertEqual(query?.first(where:{$0.name=="offset"})?.value,"30")
        XCTAssertFalse(MockURLProtocol.requests.contains{$0.httpMethod=="POST"})
    }
    func testPreviewDisabledAndHistoricalMissingFieldsAreNotInvented() throws {
        let value = try JSONDecoder().decode(ClasseraReadyPreview.self,from:preview())
        XCTAssertThrowsError(try ClasseraReadyPayload(preview:value))
        let data = try JSONDecoder().decode(ClasseraHistoryResponse.self,from:history())
        XCTAssertNil(data.records[0].template); XCTAssertNil(data.records[0].created_at)
        let stats = try JSONDecoder().decode(ClasseraStatisticsResponse.self,from:statistics())
        XCTAssertNil(stats.expected); XCTAssertNil(stats.delivery_rate)
        XCTAssertEqual(stats.counts["delivered"],1)
    }
    func testSingleClassOperationBodyAuthorizationAndDurableIdentityBeforePost() async throws {
        let value = try JSONDecoder().decode(ClasseraReadyPreview.self,from:preview(true))
        let payload = try ClasseraReadyPayload(preview:value)
        var authorized = false; var persisted = false
        let result = operation(payload.request_id)
        MockURLProtocol.handler = { request in
            XCTAssertTrue(authorized); XCTAssertTrue(persisted)
            return (202,result)
        }
        let response = try await api(authorize:{ _ in authorized = true }).sendClasseraReady(payload) { persisted = true }
        XCTAssertEqual(response.counts["accepted"],1); XCTAssertEqual(response.counts["delivered"],0)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path,"/api/classera/class-ready/operations")
        XCTAssertEqual(request.httpMethod,"POST")
        let body = try JSONDecoder().decode(ClasseraReadyPayload.self, from: requestData(request))
        XCTAssertEqual(body,payload); XCTAssertEqual(body.expected_eligible_count,1)
        XCTAssertEqual(MockURLProtocol.requests.count,1)
    }
    func testTimeoutNoPostRetryAndStatusLookupNeverSends() async throws {
        let value = try JSONDecoder().decode(ClasseraReadyPreview.self,from:preview(true))
        let payload = try ClasseraReadyPayload(preview:value)
        var persisted = false
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await api().sendClasseraReady(payload) { persisted = true }; XCTFail() }
        catch {
            guard let failure = error as? ClasseraMonitoringFailure else { return XCTFail("Expected uncertain outcome") }
            if case .uncertain = failure { } else { XCTFail("Expected uncertain outcome") }
        }
        XCTAssertTrue(persisted); XCTAssertEqual(MockURLProtocol.requests.count,1)
        let result = operation(payload.request_id)
        MockURLProtocol.handler = { _ in (200,result) }
        _ = try await api().classeraReadyOperation(payload.request_id)
        XCTAssertEqual(MockURLProtocol.requests.last?.httpMethod,"GET")
        XCTAssertEqual(MockURLProtocol.requests.filter{$0.httpMethod=="POST"}.count,1)
    }
    func testAuthorizationCancellationLockAndPersistenceFailurePreventPost() async throws {
        let value = try JSONDecoder().decode(ClasseraReadyPreview.self,from:preview(true))
        let payload = try ClasseraReadyPayload(preview:value)
        for server in [api(authorize:{_ in throw CancellationError()}), api()] {
            do { _ = try await server.sendClasseraReady(payload) { throw APIError.message("Save failed") }; XCTFail() } catch {}
        }
        var server: ServerAPI!
        server = api(authorize:{ _ in server.setAccessAllowed(false) })
        do { _ = try await server.sendClasseraReady(payload) {}; XCTFail() } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testUnavailableConflictAuthAndRedirectReturnSafeErrors() async throws {
        for status in [401,403,404,409,422,429,503,302] {
            MockURLProtocol.requests = []
            MockURLProtocol.handler = { _ in (status,Data(#"{"error":"sending_disabled","secret":"must not display"}"#.utf8)) }
            do { let _ = try await api().classeraWaitingList(); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.contains("must not display")) }
            XCTAssertEqual(MockURLProtocol.requests.count,1)
        }
    }
    func testStaleHistoryRefreshCannotOverwriteNewerState() async throws {
        let server = api();let store=ClasseraMonitoringStore(loadPending:{nil},savePending:{_ in})
        let entered=expectation(description:"First read started");var held:MockURLProtocol?
        MockURLProtocol.onStart={ protocolRequest in held=protocolRequest;entered.fulfill() }
        let old=Task { await store.load(api:server,tab:1,query:["search":"old"]) }
        await fulfillment(of:[entered],timeout:2)
        MockURLProtocol.onStart=nil
        let newData=history("New report")
        MockURLProtocol.handler={ _ in (200,newData) }
        await store.load(api:server,tab:1,query:["search":"new"])
        held?.respond(status:200,data:history("Old report"));await old.value
        XCTAssertEqual(store.history?.records.first?.report,"New report")
    }
    func testVaultReadFailureDisablesSubmissionAndClearDropsPrivateData() async throws {
        let store=ClasseraMonitoringStore(loadPending:{throw APIError.message("Locked")},savePending:{_ in XCTFail()})
        store.restore();store.preview=try JSONDecoder().decode(ClasseraReadyPreview.self,from:preview(true))
        await store.submit(api:api(),confirmed:store.preview!)
        XCTAssertFalse(store.vaultReady);XCTAssertTrue(MockURLProtocol.requests.isEmpty)
        store.history=try JSONDecoder().decode(ClasseraHistoryResponse.self,from:history())
        store.clear();XCTAssertNil(store.history);XCTAssertNil(store.preview)
    }
    func testClasseraMonitoringIPhoneLayouts() async throws {
        let w=waiting(),h=history(),s=statistics()
        MockURLProtocol.handler={ request in
            if request.url?.path.hasSuffix("waiting-list")==true{return(200,w)}
            if request.url?.path.hasSuffix("daily-statistics")==true{return(200,s)}
            return(200,h)
        }
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        for index in 0...2 {
            let store=ClasseraMonitoringStore(loadPending:{nil},savePending:{_ in})
            let window=UIWindow(windowScene:scene);window.frame=scene.coordinateSpace.bounds
            window.rootViewController=UIHostingController(rootView:NavigationStack {
                ClasseraMonitoringView(api:api(),store:store,initialTab:index)
            }.preferredColorScheme(.dark).environment(\.scenePhase,.active))
            window.makeKeyAndVisible();window.endEditing(true)
            let laidOut=expectation(description:"Layout \(index)")
            DispatchQueue.main.asyncAfter(deadline:.now()+1.5){laidOut.fulfill()}
            await fulfillment(of:[laidOut],timeout:5)
            window.layoutIfNeeded()
            let picture=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
            let attachment=XCTAttachment(image:picture);attachment.name="classera-monitoring-\(index)";attachment.lifetime = .keepAlways;add(attachment)
            if index == 2, let scroll = verticalScroll(window.rootViewController!.view) {
                scroll.setContentOffset(CGPoint(x: 0, y: min(600, max(0, scroll.contentSize.height-scroll.bounds.height))), animated: false)
                window.layoutIfNeeded()
                let lower=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
                let charts=XCTAttachment(image:lower);charts.name="classera-monitoring-charts";charts.lifetime = .keepAlways;add(charts)
            }
            window.isHidden=true
        }
        XCTAssertFalse(MockURLProtocol.requests.contains{$0.httpMethod=="POST"})
    }
    private func verticalScroll(_ view: UIView) -> UIScrollView? {
        if let scroll=view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
        for child in view.subviews { if let found=verticalScroll(child) { return found } }
        return nil
    }
    private func requestData(_ request: URLRequest) throws -> Data {
        if let body=request.httpBody{return body}
        let stream=try XCTUnwrap(request.httpBodyStream);stream.open();defer{stream.close()}
        var output=Data(),buffer=[UInt8](repeating:0,count:1024)
        while stream.hasBytesAvailable { let count=stream.read(&buffer,maxLength:buffer.count);if count<=0{break};output.append(contentsOf:buffer.prefix(count)) }
        return output
    }
}
