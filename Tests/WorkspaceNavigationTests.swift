import XCTest
import SwiftUI
@testable import Orbit

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    func testStudentsShortcutSelectsExistingTabWithoutPushingAnotherWorkspace() {
        let navigation = OrbitNavigationState()
        navigation.homePath.append(WorkspaceRoute.downloads)
        navigation.studentsPath.append(ClasseraStudentRoute(phone: "201000000001"))
        navigation.remember("subscriptions", for: "classera-detail-201000000001")
        navigation.openStudents()
        XCTAssertEqual(navigation.selectedTab, 3)
        XCTAssertEqual(navigation.homePath.count, 1)
        XCTAssertEqual(navigation.studentsPath.count, 1)
        XCTAssertEqual(navigation.anchor(for: "classera-detail-201000000001"), "subscriptions")
        navigation.openStudents()
        XCTAssertEqual(navigation.studentsPath.count, 1)
    }
    func testWorkspaceDestinationsCanRetainIndependentTypedRoutes() {
        let navigation = OrbitNavigationState()
        for route in WorkspaceRoute.allCases { navigation.homePath.append(route) }
        XCTAssertEqual(navigation.homePath.count, 5)
        navigation.openStudents()
        navigation.selectedTab = 0
        XCTAssertEqual(navigation.homePath.count, 5)
    }
}
