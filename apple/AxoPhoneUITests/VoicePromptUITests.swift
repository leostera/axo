import XCTest

final class VoicePromptUITests: XCTestCase {
    @MainActor
    func testApprovedSetupImmediatelyRecordsAndTranscriptionUsesTheSendSpinner() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-voice-preview", "-appleSpeechSetupApproved", "NO"]
        app.launch()
        let voice = app.buttons["voicePromptButton"]
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.tap()
        app.alerts["Set up Apple on-device speech?"].buttons["Continue"].tap()
        XCTAssertTrue(app.buttons["Stop and send"].waitForExistence(timeout: 5), "Continue must start recording without another tap")
        voice.tap()
        let send = app.buttons["sendPromptButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertEqual(send.label, "Transcribing")
        XCTAssertFalse(send.isEnabled)
        XCTAssertTrue(send.activityIndicators.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Transcribing on this iPhone…"].exists)
        app.buttons["Cancel transcription"].tap()
        // NSArgumentDomain's forced NO shadows persisted defaults for the entire launch.
        // Relaunch with the approved state instead of mistaking that fixture for a consent bug.
        app.terminate()
        app.launchArguments = ["--axo-voice-preview", "-appleSpeechSetupApproved", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Record"].waitForExistence(timeout: 5))
        app.buttons["voicePromptButton"].tap()
        XCTAssertTrue(app.buttons["Stop and send"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Set up Apple on-device speech?"].exists)
    }

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
