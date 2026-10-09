import XCTest

final class WorkbenchShellUITests: XCTestCase {
    @MainActor
    func testEdgeSwipeFromChatOpensSessionMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-workbench-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["conversation-title"].waitForExistence(timeout: 10))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(app.staticTexts["workbench-menu-title"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testMenuSearchSelectsASessionAndShowsTheSessionList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-workbench-preview"]
        app.launch()

        let conversationTitle = app.staticTexts.matching(identifier: "conversation-title").firstMatch
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(conversationTitle.label, "Phone shell")

        app.buttons["Sessions menu"].tap()
        XCTAssertTrue(app.staticTexts["workbench-menu-title"].waitForExistence(timeout: 3))
        let searchButton = app.buttons["Search sessions"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        searchButton.tap()
        XCTAssertTrue(app.staticTexts["Search workspaces and sessions"].waitForExistence(timeout: 3))
        let scopeNotice = app.staticTexts.matching(identifier: "catalog-search-scope").firstMatch
        XCTAssertTrue(scopeNotice.waitForExistence(timeout: 3))
        XCTAssertTrue(scopeNotice.label.contains("not conversation text"))

        let searchField = app.textFields.matching(identifier: "catalog-search-field").firstMatch
        searchField.tap()
        searchField.typeText("Research notes")
        let result = app.buttons["catalog-result-session:44444444-4444-4444-8444-444444444444"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.tap()
        XCTAssertEqual(conversationTitle.label, "Research notes")

        app.buttons["Sessions menu"].tap()
        XCTAssertTrue(app.staticTexts["Axo Project"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Research"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "session-22222222-2222-4222-8222-222222222222").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "session-44444444-4444-4444-8444-444444444444").firstMatch.exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["New session"].exists)
    }

    @MainActor
    func testSettingsAreFocusedOnThemeAndDoNotExposeConnectionDetails() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-workbench-preview"]
        app.launch()
        app.buttons["Sessions menu"].tap()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "appearancePicker").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "accentColorPicker").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Mac"].exists)
        XCTAssertFalse(app.staticTexts["Connection"].exists)
        XCTAssertFalse(app.staticTexts["Voice prompting"].exists)
        XCTAssertFalse(app.staticTexts["Data and privacy"].exists)
        XCTAssertTrue(app.buttons["Close settings"].exists)
    }
}
