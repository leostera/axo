import XCTest

final class CentralPhoneWorkbenchUITests: XCTestCase {
    @MainActor
    func testPrimaryPhoneShowsExactCentralSessionAndFailsClosedBeforeAdmission() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-control-plane-preview"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Axo"].waitForExistence(timeout: 5))
        let sessionID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let session = app.buttons["control-plane-session-open-\(sessionID)"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertTrue(session.label.contains("Build the phone app"))
        session.tap()

        XCTAssertTrue(app.staticTexts["Pi is not admitted"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'no Pi admission exists'")).firstMatch.exists)
        let composer = app.descendants(matching: .any)["central-pi-composer"]
        XCTAssertTrue(composer.exists)
        XCTAssertFalse(composer.isEnabled)
        let send = app.buttons["central-pi-send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Unavailable Pi must not show a successful or actionable composer")
        let voice = app.buttons["voicePromptButton"]
        XCTAssertTrue(voice.exists)
        XCTAssertFalse(voice.isEnabled, "Voice capture requires the same exact admitted live binding as typed input")

        app.buttons["Close"].tap()
        XCTAssertTrue(session.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPrimarySettingsRemainAvailableWithoutLegacyWorkbenchRoute() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-control-plane-preview"]
        app.launch()

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["private-machine-browser"].exists)
    }
}
