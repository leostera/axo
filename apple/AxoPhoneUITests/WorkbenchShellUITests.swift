import XCTest

final class WorkbenchShellUITests: XCTestCase {
    @MainActor
    func testSidebarSearchFindsCatalogNamesAndSelectsTheMatchingSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-workbench-preview"]
        app.launch()

        let welcomeTitle = app.staticTexts["workbench-welcome-title"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5))
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10))
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
        let conversationTitle = app.buttons.matching(identifier: "conversation-title").firstMatch
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 3))

        let browse = app.buttons["Workspaces and sessions"]
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        browse.tap()
        XCTAssertTrue(app.staticTexts["Axo Project"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Research"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "session-22222222-2222-4222-8222-222222222222").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "session-44444444-4444-4444-8444-444444444444").firstMatch.exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    @MainActor
    func testSettingsShellHasDistinctAppearanceConnectionVoiceAndPrivacyPages() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-workbench-preview"]
        app.launch()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Mac"].exists)
        XCTAssertTrue(app.buttons["Voice prompting"].exists)
        XCTAssertTrue(app.buttons["Data and privacy"].exists)

        app.buttons["Appearance"].tap()
        XCTAssertTrue(app.segmentedControls["appearancePicker"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        app.buttons["Voice prompting"].tap()
        XCTAssertTrue(app.navigationBars["Voice prompting"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Apple on-device speech"].exists)
        app.buttons["Done"].tap()

        app.buttons["Data and privacy"].tap()
        XCTAssertTrue(app.navigationBars["Data and privacy"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Drafts remain in the current app session."].exists)
    }
}
