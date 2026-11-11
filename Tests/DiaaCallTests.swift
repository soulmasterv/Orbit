import XCTest
@testable import Orbit

@MainActor
final class DiaaCallTests: XCTestCase {
    func testLocalAndInternationalNumbersNormalizeToSameDestination() {
        XCTAssertEqual(DiaaCallNumber.normalized(" 01012345678 "), "+201012345678")
        XCTAssertEqual(DiaaCallNumber.normalized("+201012345678"), "+201012345678")
        XCTAssertEqual(DiaaCallNumber.normalized("+442079460000"), "+442079460000")
        XCTAssertNil(DiaaCallNumber.normalized("0101234567"))
        XCTAssertNil(DiaaCallNumber.normalized("0101234567a"))
        XCTAssertNil(DiaaCallNumber.normalized("02012345678"))
    }

    func testContactNumberFormattingPreservesTheDestination() {
        XCTAssertEqual(DiaaCallNumber.normalized("010 1234 5678"), "+201012345678")
        XCTAssertEqual(DiaaCallNumber.normalized("+20 (101) 234-5678"), "+201012345678")
        XCTAssertNil(DiaaCallNumber.normalized("+20 101 234 5678 ext. 9"))
        XCTAssertNil(DiaaCallNumber.normalized("010 1234 5678,9"))
    }

    func testForegroundHandoffWaitsForTheAppToBecomeActive() async throws {
        var checks = 0
        try await DeviceAuthorization.waitForCallForeground(isForeground: {
            checks += 1
            return checks == 2
        }, mayContinue: { true })
        XCTAssertEqual(checks, 2)
    }

    func testForegroundHandoffStopsIfTheSessionWasInvalidated() async {
        var checkedForeground = false
        do {
            try await DeviceAuthorization.waitForCallForeground(isForeground: {
                checkedForeground = true
                return true
            }, mayContinue: { false })
            XCTFail("A revoked session must never submit a call.")
        } catch {
            XCTAssertFalse(checkedForeground)
        }
    }
}
