import XCTest
@testable import Orbit

final class JarvisMemoryAndSchedulesTests: XCTestCase {
    func testOlderQueueWithoutSchedulesStillDecodes() throws {
        let queue = try JSONDecoder().decode(OrbitPhoneQueue.self, from: Data(#"{"jobs":[]}"#.utf8))
        XCTAssertNil(queue.schedules)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testCairoClockAndSundayBasedWeekdays() throws {
        let data = Data(#"{"jobs":[],"schedules":[{"id":"fixture","date":"2026-11-20","time":"00:05","days":[6,0,2],"once":false,"reminder":"Test reminder"}]}"#.utf8)
        let queue = try JSONDecoder().decode(OrbitPhoneQueue.self, from: data)
        let schedule = try XCTUnwrap(queue.schedules?.first)
        XCTAssertEqual(schedule.cairoTime, "12:05 AM Cairo")
        XCTAssertEqual(schedule.recurrence, "Sun, Tue, Sat · Starts 2026-11-20")
        let noon = OrbitPhoneQueue.Schedule(id: "noon", date: "2026-11-20", time: "12:30", days: [], once: true, reminder: "")
        XCTAssertEqual(noon.cairoTime, "12:30 PM Cairo")
        XCTAssertEqual(noon.recurrence, "2026-11-20")
    }

    func testMemoryDecodesIndependentSavingSharingAndSensitivity() throws {
        let data = Data(#"{"memory":{"enabled":false,"shareWithAI":true,"blockedTopics":["private"],"entries":[{"id":"fixture","text":"Test memory","type":"manual","sensitive":true,"createdAt":"2026-11-19T12:00:00.000Z","source":"dashboard"}]}}"#.utf8)
        let value = try JSONDecoder().decode(JarvisMemoryResponse.self, from: data)
        let memory = try XCTUnwrap(value.memory)
        XCTAssertFalse(memory.enabled)
        XCTAssertTrue(memory.shareWithAI)
        XCTAssertTrue(try XCTUnwrap(memory.entries.first).sensitive)
        XCTAssertEqual(memory.blockedTopics, ["private"])
        let old = try JSONDecoder().decode(JarvisMemoryResponse.self, from: Data("{}".utf8))
        XCTAssertNil(old.memory)
    }
}
