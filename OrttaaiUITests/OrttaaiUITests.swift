import XCTest

final class OrttaaiUITests: XCTestCase {
    func testSidebarNavigationChangesHomeSection() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedSetup", "YES",
            "-homeWorkspaceAutoOpenEnabled", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 10))

        app.buttons["Sidebar-Memory"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Auto-correct your preferred terms."].waitForExistence(timeout: 5))

        app.buttons["Sidebar-About"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Build info, creator details, and open-source components."].waitForExistence(timeout: 5))

        app.buttons["Sidebar-Overview"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
    }
}
