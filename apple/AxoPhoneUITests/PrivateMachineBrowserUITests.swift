import XCTest

final class PrivateMachineBrowserUITests: XCTestCase {
    @MainActor
    func testPreviewShowsOnlineOfflineAndHistoricalRuntimeMetadata() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-workbench-preview", "--axo-control-plane-preview"]
        app.launch()

        app.buttons["Sessions menu"].tap()
        app.buttons["Settings"].tap()
        let browserLink = app.buttons["private-machine-browser"]
        XCTAssertTrue(browserLink.waitForExistence(timeout: 5))
        browserLink.tap()

        XCTAssertTrue(app.navigationBars["Private machines"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["machine-11111111-1111-4111-8111-111111111111"].exists)
        XCTAssertTrue(app.staticTexts["Studio Mac"].exists)
        XCTAssertTrue(app.staticTexts["Travel Mac"].exists)
        XCTAssertTrue(app.staticTexts["machine-online-status"].exists)
        XCTAssertTrue(app.otherElements["machine-runtime-current"].exists || app.staticTexts["machine-runtime-current"].exists)
        XCTAssertTrue(app.otherElements["machine-runtime-historical"].exists || app.staticTexts["machine-runtime-historical"].exists)

        app.buttons["machine-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"].tap()
        XCTAssertTrue(app.staticTexts["control-plane-stale-banner"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["machine-runtime-historical"].exists)

        app.buttons["machine-44444444-4444-4444-8444-444444444444"].tap()
        XCTAssertTrue(app.staticTexts["control-plane-offline-banner"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["machine-offline-status"].exists)
        XCTAssertTrue(app.staticTexts["machine-runtime-historical"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'cached runtime metadata is historical'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["control-plane-reconnect"].exists)
    }
}
