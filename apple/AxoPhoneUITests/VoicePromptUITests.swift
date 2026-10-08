import XCTest

final class VoicePromptUITests: XCTestCase {
    @MainActor
    func testDownloadRequiresConfirmationAndCanBeDeclined() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-appleSpeechSetupApproved", "NO"]
        app.launch()
        let setup = app.buttons["Set up voice"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.tap()
        let confirmation = app.alerts["Set up Apple on-device speech?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.buttons["Continue"].exists)
        confirmation.buttons["Not now"].tap()
        XCTAssertTrue(setup.exists)
        XCTAssertFalse(app.buttons["Record"].exists)
        XCTAssertFalse(app.buttons["Send"].exists)
    }

    @MainActor
    func testVoiceDetailsExplainLocalProcessingAndAttribution() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-appleSpeechSetupApproved", "NO"]
        app.launch()
        let options = app.buttons["Composer options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["About on-device voice prompting"].tap()
        XCTAssertTrue(app.navigationBars["Voice prompting"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Apple on-device speech"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Set up voice"].exists)
    }
}
