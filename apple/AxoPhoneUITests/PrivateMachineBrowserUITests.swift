import XCTest

final class PrivateMachineBrowserUITests: XCTestCase {
    @MainActor
    func testPreviewKeepsWorkSessionsDistinctAndOfflineCatalogExplicit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-workbench-preview", "--axo-control-plane-preview"]
        app.launch()

        app.buttons["Sessions menu"].tap()
        app.buttons["Settings"].tap()
        let browserLink = app.buttons["private-machine-browser"]
        XCTAssertTrue(browserLink.waitForExistence(timeout: 5))
        browserLink.tap()

        XCTAssertTrue(app.navigationBars["Private machines"].waitForExistence(timeout: 5))
        let studio = app.buttons["machine-11111111-1111-4111-8111-111111111111"]
        XCTAssertTrue(studio.exists)
        XCTAssertTrue(studio.label.contains("Studio Mac"))
        XCTAssertTrue(app.staticTexts["Build the phone app"].exists)
        XCTAssertTrue(app.staticTexts["No runtime observed"].exists)
        XCTAssertTrue(app.staticTexts["Pi not admitted"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not a Pi chat'")).firstMatch.exists)

        app.buttons["machine-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"].tap()
        XCTAssertTrue(app.buttons["control-plane-reconnect"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["machine-runtime-historical"].exists)

        app.buttons["machine-44444444-4444-4444-8444-444444444444"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["control-plane-offline-banner"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["machine-offline-status"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'metadata are not shown'")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["machine-runtime-historical"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["machine-runtime-current"].exists)
        XCTAssertFalse(app.buttons["control-plane-reconnect"].exists)
    }
}
