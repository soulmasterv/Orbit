import XCTest
import SwiftUI
import UIKit
@testable import Orbit

@MainActor
final class DeliveryStatusTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        suite = "DeliveryStatusTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api() -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
                         tokenProvider: { "owner-placeholder" }, authorize: { _ in })
    }
    private func response(_ state: String) -> Data {
        Data("""
        {"version":1,"records":[{"id":"fixture","report":"Daily report","report_date":"2026-10-28","class_id":"12F",
        "phone":"201000000001","student":"Sample Student","template":"classera_v9","message_id":"mock-message",
        "status":"\(state)","created_at":1793130000,"updated_at":1793130100,"historical":false}],
        "total":1,"offset":0,"next_offset":null,"updated_at":1793130100,"limitations":[]}
        """.utf8)
    }
    func testExactDeliveryIdentityRefreshCanAdvanceSentToReadWithoutSending() async throws {
        let server = api();let first = response("sent");let latest = response("read")
        var reads = 0
        MockURLProtocol.handler = { _ in reads += 1; return (200, reads == 1 ? first : latest) }
        let old = try await server.classeraDeliveryHistory(["record_id":"fixture","limit":"1"])
        let new = try await server.classeraDeliveryHistory(["record_id":"fixture","limit":"1"])
        XCTAssertEqual(old.records.first?.status,"sent");XCTAssertEqual(new.records.first?.status,"read")
        XCTAssertEqual(MockURLProtocol.requests.count,2)
        for request in MockURLProtocol.requests {
            XCTAssertEqual(request.httpMethod,"GET")
            let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL:false)?.queryItems
            XCTAssertEqual(items?.first { $0.name == "record_id" }?.value,"fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer owner-placeholder")
            XCTAssertNil(request.value(forHTTPHeaderField:"X-API-Key"))
        }
    }
    func testDeliveredSchoolOperationKeepsWatchingForReadReceipt() throws {
        func message(_ state: String) throws -> AdminMessage {
            try JSONDecoder().decode(AdminMessage.self,from:Data("""
            {"request_id":"00000000-0000-0000-0000-000000000001","phone":"201000000001","status":"\(state)","created_at":1,"updated_at":2}
            """.utf8))
        }
        for state in ["pending","unknown","accepted","sent","delivered"] { XCTAssertTrue(try message(state).awaitsReadReceipt) }
        for state in ["read","failed","cancelled"] { XCTAssertFalse(try message(state).awaitsReadReceipt) }
        XCTAssertFalse(try message("delivered").needsRecovery) // Existing mutation-recovery rules stay separate.
    }
    func testFaceIDSettingSelectsConfirmationOnlyWithoutSkippingConfirmation() async throws {
        XCTAssertEqual(DeviceAuthorization.requirement(defaults:defaults,confirmed:false),.deviceAuthentication)
        defaults.set(false,forKey:"appLock.v4")
        XCTAssertEqual(DeviceAuthorization.requirement(defaults:defaults,confirmed:false),.confirmation)
        XCTAssertEqual(DeviceAuthorization.requirement(defaults:defaults,confirmed:true),.alreadyConfirmed)
        try await DeviceAuthorization.$confirmationProvided.withValue(true) {
            try await DeviceAuthorization.authorize(reason:"Fixture confirmed action",defaults:defaults)
        }
        defaults.set(true,forKey:"appLock.v4")
        XCTAssertEqual(DeviceAuthorization.requirement(defaults:defaults,confirmed:true),.deviceAuthentication)
        XCTAssertTrue(DeviceAuthorization.isCancellation(CancellationError()))
    }
    func testDeliveryDetailRefreshesItsInitialSentSnapshotOnIPhone() async throws {
        let initial = try JSONDecoder().decode(ClasseraHistoryResponse.self,from:response("sent")).records[0]
        let latest = response("read");MockURLProtocol.handler = { _ in (200,latest) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene);window.frame=scene.coordinateSpace.bounds
        window.rootViewController=UIHostingController(rootView:NavigationStack {
            ClasseraDeliveryDetail(api:api(),record:initial)
        }.preferredColorScheme(.dark).environment(\.scenePhase,.active))
        window.makeKeyAndVisible()
        let ready=expectation(description:"Delivery refresh")
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5){ready.fulfill()}
        await fulfillment(of:[ready],timeout:5)
        XCTAssertTrue(MockURLProtocol.requests.contains { $0.url?.query?.contains("record_id=fixture") == true })
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        let image=UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let attachment=XCTAttachment(image:image);attachment.name="classera-delivery-live-read";attachment.lifetime = .keepAlways;add(attachment)
        window.isHidden=true
    }
}
