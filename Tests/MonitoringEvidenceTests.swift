import XCTest
@testable import Orbit

final class MonitoringEvidenceTests: XCTestCase {
    func testExplicitFullReportTitleDatesAndInvalidDates() {
        XCTAssertEqual(ClasseraReportTitleDate.parse("12F 1/11/26"), "2026-11-01")
        XCTAssertEqual(ClasseraReportTitleDate.parse("12E 01_11_2026"), "2026-11-01")
        XCTAssertEqual(ClasseraReportTitleDate.parse("12E 29/2/24"), "2024-02-29")
        XCTAssertNil(ClasseraReportTitleDate.parse("12F 29/2/26"))
        XCTAssertNil(ClasseraReportTitleDate.parse("12F 1/11"))
        XCTAssertNil(ClasseraReportTitleDate.parse("Unknown report"))
    }
    func testHistoryLabelsTitleDateWithoutChangingStoredEvidence() throws {
        let value = try JSONDecoder().decode(ClasseraDeliveryRecord.self, from: Data(#"{"id":"fixture","report":"12F 1/11/26","report_date":null,"class_id":"12F","phone":"201000000001","student":null,"template":"classera_v9","message_id":null,"status":"delivered","created_at":null,"updated_at":1,"historical":true}"#.utf8))
        XCTAssertNil(value.report_date)
        XCTAssertEqual(value.displayReportDate, "2026-11-01")
        XCTAssertTrue(value.dateFromTitle)
        XCTAssertEqual(value.template, "classera_v9")
    }

    func testStoredDateWinsAndMissingLegacyMetadataIsNotInvented() throws {
        let value = try JSONDecoder().decode(ClasseraDeliveryRecord.self, from: Data(#"{"id":"fixture","report":"12F 1/11/26","report_date":"2026-10-31","class_id":"12F","phone":"201000000001","status":"sent","updated_at":1,"historical":true}"#.utf8))
        XCTAssertEqual(value.displayReportDate, "2026-10-31")
        XCTAssertFalse(value.dateFromTitle)
        XCTAssertNil(value.template)
        XCTAssertNil(value.report_date_source)
    }
}
