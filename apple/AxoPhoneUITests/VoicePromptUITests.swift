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
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 5), "Continue must start recording without another tap")
        XCTAssertTrue(app.buttons["Send recording"].exists)
        app.buttons["Stop recording"].tap()
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
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Set up Apple on-device speech?"].exists)
    }

    @MainActor
    func testStopTranscribesIntoDraftForReview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-voice-preview", "--axo-voice-preview-fast", "-appleSpeechSetupApproved", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Record"].waitForExistence(timeout: 10))
        app.buttons["Record"].tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 5))
        app.buttons["Stop recording"].tap()
        let draft = app.descendants(matching: .any).matching(identifier: "promptDraft").firstMatch
        let reviewed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Synthetic dictated prompt"), object: draft)
        XCTAssertEqual(XCTWaiter.wait(for: [reviewed], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["Send"].exists)
        XCTAssertFalse(app.buttons["voiceRecordingBar"].exists)
    }

    @MainActor
    func testSendRecordingRetainsTranscriptWhenOffline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-voice-preview", "--axo-voice-preview-fast", "-appleSpeechSetupApproved", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Record"].waitForExistence(timeout: 10))
        app.buttons["Record"].tap()
        XCTAssertTrue(app.buttons["Send recording"].waitForExistence(timeout: 5))
        app.buttons["Send recording"].tap()
        let draft = app.descendants(matching: .any).matching(identifier: "promptDraft").firstMatch
        let retained = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Synthetic dictated prompt"), object: draft)
        XCTAssertEqual(XCTWaiter.wait(for: [retained], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["sendPromptButton"].isEnabled)
    }

    @MainActor
    func testCancelRecordingPreservesTypedDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-voice-preview", "-appleSpeechSetupApproved", "YES"]
        app.launch()
        let draft = app.descendants(matching: .any).matching(identifier: "promptDraft").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("Keep my edited draft")
        app.buttons["voicePromptButton"].tap()
        XCTAssertTrue(app.buttons["Cancel recording"].waitForExistence(timeout: 5))
        app.buttons["Cancel recording"].tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Keep my edited draft")
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
        let options = app.buttons["Chat options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["About voice"].tap()
        XCTAssertTrue(app.navigationBars["Voice prompting"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Apple on-device speech"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Set up voice"].exists)
    }
}
