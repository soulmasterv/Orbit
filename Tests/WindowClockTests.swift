import XCTest
@testable import Orbit

final class WindowClockTests: XCTestCase {
    func testTwelveHourClockHandlesNoonMidnightAndTimeZone() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(WindowClock.time(Date(timeIntervalSince1970: 0), timeZone: utc), "12:00 AM")
        XCTAssertEqual(WindowClock.time(Date(timeIntervalSince1970: 12 * 3600), timeZone: utc), "12:00 PM")
        XCTAssertEqual(WindowClock.time(Date(timeIntervalSince1970: 22 * 3600 + 30 * 60), timeZone: utc), "10:30 PM")
        let plus3 = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600))
        XCTAssertEqual(WindowClock.time(Date(timeIntervalSince1970: 19 * 3600 + 30 * 60), timeZone: plus3), "10:30 PM")
        XCTAssertNil(WindowClock.time(Date(timeIntervalSince1970: .infinity)))
    }
    func testClasseraClosingClockKeepsRealTwentyFourHourWindowAndLocalExpiry() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let inbound = 22 * 3600 + 30 * 60
        let window = ClasseraWhatsAppWindow(className: "12F", windowOpen: true, secondsLeft: 5400, lastInboundAt: inbound)
        let start = ContinuousClock.now
        XCTAssertEqual(window.displayLabel(since: start, at: start, timeZone: utc), "Open until 10:30 PM")
        XCTAssertEqual(window.remainingSeconds(since: start, at: start), 5400)
        XCTAssertEqual(window.displayLabel(since: start, at: start.advanced(by: .seconds(5400)), timeZone: utc), "Closed")
        let missing = ClasseraWhatsAppWindow(className: "12F", windowOpen: nil, secondsLeft: nil, lastInboundAt: nil)
        XCTAssertEqual(missing.displayLabel(since: start, at: start, timeZone: utc), "Unknown")
    }
    func testSchoolClosingClockUsesServerSnapshotAndDoesNotAlterEligibility() throws {
        let data = Data(#"{"phone":"201000000001","name":"Student","grade":"12","state":"active","window_open":true,"seconds_left":5400}"#.utf8)
        let student = try JSONDecoder().decode(Student.self, from: data)
        let start = ContinuousClock.now
        let snapshot = StudentsSnapshot(students: [student], receivedAt: Date(timeIntervalSince1970: 21 * 3600), receivedInstant: start)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(snapshot.windowLabel(for: student, at: start, timeZone: utc), "Open until 10:30 PM")
        XCTAssertEqual(snapshot.countdown(for: student, at: start), "01:30")
        XCTAssertEqual(snapshot.windowLabel(for: student, at: start.advanced(by: .seconds(5400)), timeZone: utc), "Window closed")
    }
}

