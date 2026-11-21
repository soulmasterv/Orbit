import XCTest
@testable import Orbit

@MainActor
final class JarvisFunCallTests: XCTestCase {
    func testDefaultOwnerAndBiboDefaultOmitOptionalFields() throws {
        for mode in JarvisFunMode.allCases {
            let request = try JarvisFunCallRequest(mode: mode, number: nil, message: "")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            XCTAssertEqual(json["operation"] as? String, "fun_call")
            XCTAssertEqual(json["mode"] as? String, mode.rawValue)
            XCTAssertNotNil(UUID(uuidString: request.request_id))
            XCTAssertNil(json["destination"])
            XCTAssertNil(json["message"])
        }
        XCTAssertEqual(JarvisFunMode.silly.title, "Hossam")
    }

    func testNumbersNormalizeAndOnlyBiboIncludesMessage() throws {
        for number in ["010 1234 5678", "+20 (101) 234-5678", "00201012345678", "201012345678"] {
            let request = try JarvisFunCallRequest(mode: .bibo, number: number, message: " Feed Bibo ")
            XCTAssertEqual(request.destination, "+201012345678")
            XCTAssertEqual(request.message, "Feed Bibo")
        }
        XCTAssertNil(try JarvisFunCallRequest(mode: .diaa, number: nil, message: "old Bibo draft").message)
        XCTAssertThrowsError(try JarvisFunCallRequest(mode: .bibo, number: "", message: ""))
        XCTAssertThrowsError(try JarvisFunCallRequest(mode: .bibo, number: "01012345678 ext 9", message: ""))
        XCTAssertThrowsError(try JarvisFunCallRequest(mode: .bibo, number: nil, message: String(repeating: "a", count: 1001)))
    }

    func testInFlightRequestIDStaysStableAndSecondTapSendsNothing() async throws {
        let store = JarvisFunCallSubmission()
        let first = try JarvisFunCallRequest(mode: .diaa, number: nil, message: "")
        let second = try JarvisFunCallRequest(mode: .bibo, number: nil, message: "")
        var sends = 0
        await store.submit(first, authorize: {}, send: { request in
            sends += 1
            XCTAssertEqual(store.requestID, first.request_id)
            XCTAssertEqual(request.request_id, first.request_id)
            await store.submit(second, authorize: { XCTFail("Second tap must not authorize.") }, send: { _ in XCTFail(); return true })
            XCTAssertEqual(store.requestID, first.request_id)
            return true
        })
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(store.result, "Call queued.")
        XCTAssertFalse(store.busy)
    }

    func testUncertainResponseIsNeverRetriedAndAuthorizationFailureSendsNothing() async throws {
        let store = JarvisFunCallSubmission()
        let request = try JarvisFunCallRequest(mode: .silly, number: nil, message: "")
        var sends = 0
        await store.submit(request, authorize: { throw CancellationError() }, send: { _ in sends += 1; return true })
        XCTAssertEqual(sends, 0)
        XCTAssertFalse(store.uncertain)
        await store.submit(request, authorize: {}, send: { _ in sends += 1; throw URLError(.timedOut) })
        XCTAssertTrue(store.uncertain)
        XCTAssertTrue(store.result?.contains("Check Tasks") == true)
        await store.submit(request, authorize: { XCTFail() }, send: { _ in sends += 1; return true })
        XCTAssertEqual(sends, 1)
        store.acknowledgeTasksChecked()
        XCTAssertFalse(store.uncertain)
    }
}
