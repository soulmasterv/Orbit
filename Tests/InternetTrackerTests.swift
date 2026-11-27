import XCTest
@testable import Orbit

@MainActor final class InternetTrackerTests: XCTestCase {
    private func snapshot(operation: String? = nil, pending: Bool = false) throws -> InternetTrackerSnapshot {
        var value: [String: Any] = ["version": 1, "phone": "201000000001", "allowed": true,
            "permissionGranted": true, "permissionEditable": true, "friendChecksEnabled": true,
            "revision": String(repeating: "a", count: 64), "policy": "fixture-v1", "audioProvider": "Fixture",
            "lines": [], "pending": pending, "history": []]
        if let operation { value["operation"] = operation }
        return try JSONDecoder().decode(InternetTrackerSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testLandlinesAcceptLocalAndInternationalFormattingOnly() {
        for input in ["0234567890", "+20 2 3456 7890", "0020 (2) 3456-7890"] {
            XCTAssertEqual(InternetTrackerFormat.landline(input), "0234567890")
        }
        for input in ["01012345678", "abc0234567890", "0234", "0234567890/path"] {
            XCTAssertNil(InternetTrackerFormat.landline(input))
        }
    }
    func testChecksNeedExplicitDeliveryAndConsentAndKeepStableRequestID() {
        var change = InternetTrackerChange(action: "check", revision: String(repeating: "a", count: 64))
        let id = change.request_id; change.slot = 2
        XCTAssertFalse(change.valid)
        change.channel = "sms"; change.policy = "fixture-v1"; change.confirmed = true
        XCTAssertTrue(change.valid); XCTAssertEqual(change.request_id, id)
        change.channel = "push"; XCTAssertFalse(change.valid)
    }
    func testUnknownAllowanceAndZeroRemainDistinct() throws {
        func event(_ remaining: String) throws -> InternetTrackerSnapshot.Event {
            try JSONDecoder().decode(InternetTrackerSnapshot.Event.self, from: Data("""
            {"id":"fixture","number":"0234567890","provider":"we","status":"completed","remaining":\(remaining),"recordingAvailable":false,"recordingExpired":true,"channel":"sms"}
            """.utf8))
        }
        XCTAssertEqual(try event("null").allowance, "Couldn’t read the remaining allowance.")
        XCTAssertEqual(try event("[]").allowance, "Couldn’t read the remaining allowance.")
        XCTAssertEqual(try event(#"[{"amount":"0","unit":"GB"}]"#).allowance, "0 GB remaining")
        XCTAssertFalse(try event(#"[{"amount":"10","unit":"%"}]"#).hasAllowance)
        XCTAssertTrue(try event("null").expired())
    }
    func testDisplayUsesTwelveHourTimeWithoutTimezoneCaption() {
        let text = InternetTrackerFormat.time(1_800_000_000_000)
        XCTAssertTrue(text.contains("AM") || text.contains("PM"))
        XCTAssertFalse(text.contains("Cairo")); XCTAssertEqual(InternetTrackerFormat.time(nil), "Unavailable")
    }
    func testPendingContactPreventsSecondSlotCheckAndSettingsNeverQueue() async throws {
        let state = InternetTrackerStore(); let pending = try snapshot(pending: true)
        await state.load { pending }
        var change = InternetTrackerChange(action: "check", revision: pending.revision)
        change.slot = 2; change.channel = "whatsapp"; change.confirmed = true; change.policy = pending.policy
        var submissions = 0
        let accepted = await state.submit(change) { _ in submissions += 1; return pending }
        XCTAssertFalse(accepted); XCTAssertEqual(submissions, 0)
        state.clear(); XCTAssertNil(state.value)
    }
    func testUncertainResponseDoesNotAutomaticallyRetry() async throws {
        let state = InternetTrackerStore(); let initial = try snapshot()
        await state.load { initial }
        var change = InternetTrackerChange(action: "permission", revision: initial.revision); change.enabled = false
        var count = 0
        let first = await state.submit(change) { _ in count += 1; throw URLError(.timedOut) }
        let second = await state.submit(change) { _ in count += 1; return initial }
        XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertEqual(count, 1); XCTAssertTrue(state.uncertain)
        await state.load { initial }; XCTAssertFalse(state.uncertain)
    }
}
