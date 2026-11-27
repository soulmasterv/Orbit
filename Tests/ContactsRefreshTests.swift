import XCTest
@testable import Orbit

final class ContactsRefreshTests: XCTestCase {
    func testOnlyCurrentIncomingAndFunModesAreOfferedWithNewLabels() throws {
        XCTAssertEqual(OrbitIncomingMode.allCases.map(\.rawValue), ["jarvis", "silly", "bibo", "diaa"])
        XCTAssertEqual(JarvisFunMode.allCases.map(\.rawValue), ["silly", "bibo", "diaa"])
        XCTAssertEqual(OrbitIncomingMode.jarvis.title, "Private AI")
        XCTAssertEqual(OrbitIncomingMode.diaa.title, "Diaa")
        XCTAssertEqual(JarvisFunMode.diaa.title, "Diaa")
        XCTAssertFalse(OrbitIncomingOverrideChange(action: "override", mode: "diaa-noqta", minutes: 10).isValid)
        let old = OrbitAllowedCaller(number: "+201000000001", name: "Fixture", enabled: true, modes: ["diaa-noqta", "diaa"], defaultMode: "diaa-noqta", selectedMode: nil)
        let draft = OrbitCallerDraft(old)
        XCTAssertEqual(draft.defaultMode, "diaa"); XCTAssertEqual(old.displayModes, ["diaa"])
        XCTAssertEqual(draft.change(available: ["diaa"], existing: [old])?.modes, ["diaa"])
    }
    func testUnfilteredClasseraContactsIncludeOptedOutAndKeepSuspendedLast() throws {
        func row(_ phone: String, status: String, activity: String) -> [String: Any] {
            ["phone": phone, "profile_name": phone, "activity_status": activity,
             "subscriptions": [["class_name":"12F","name":phone,"status":status,"ai_enabled":1]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version":1,"students":[
            row("201000000001", status:"active", activity:"suspended"),
            row("201000000002", status:"opted_out", activity:"allowed"),
            row("201000000003", status:"paused", activity:"allowed")]])
        let values = try JSONDecoder().decode(ClasseraDirectoryResponse.self, from: data).students
        XCTAssertEqual(ClasseraDirectoryFilter.unfiltered(values, search: "").map(\.phone), ["201000000002","201000000003","201000000001"])
        XCTAssertEqual(ClasseraDirectoryFilter.unfiltered(values, search: "000002").map(\.phone), ["201000000002"])
    }
    func testHistoryDecodesCurrentCoverageAndOlderResponses() throws {
        for suffix in ["", ",\"coverage\":\"recorded_diaa_calls\""] {
            let data = Data(("{\"total\":1,\"calls\":[{\"id\":\"fixture\",\"seen_at\":1795000000}]" + suffix + "}").utf8)
            let result = try JSONDecoder().decode(OrbitDiaaCallHistory.self, from: data)
            XCTAssertEqual(result.calls.first?.id, "fixture"); XCTAssertEqual(result.total, 1)
        }
    }
}
