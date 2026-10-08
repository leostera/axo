import XCTest

final class ChatLayoutUITests: XCTestCase {
    @MainActor
    func testConnectionSettingsAreOutOfTheChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview"]
        app.launch()
        let settings = app.buttons["Connection settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["relayEndpoint"].exists)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["relayEndpoint"].exists)
        XCTAssertTrue(app.buttons["Sign in with Cloudflare Access"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Composer options"].exists)
    }

    @MainActor
    func testComposerActionsSitBelowTheTextField() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview"]
        app.launch()
        let input = app.descendants(matching: .any).matching(identifier: "promptDraft").firstMatch
        let options = app.buttons["Composer options"]
        let voice = app.buttons["voicePromptButton"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(options.exists)
        XCTAssertTrue(voice.exists)
        XCTAssertFalse(app.staticTexts["Checking microphone access…"].exists)
        XCTAssertGreaterThan(options.frame.minY, input.frame.minY)
        XCTAssertEqual(options.frame.midY, voice.frame.midY, accuracy: 4)
    }

    @MainActor
    func testRunningPreviewShowsThinkingAndToolActivity() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview-working"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Pi is calling tools…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Thinking block · content not shared"].exists)
        XCTAssertTrue(app.staticTexts["bash"].exists)
        XCTAssertTrue(app.staticTexts["All protocol and bridge tests passed."].exists)
        XCTAssertTrue(app.staticTexts["File not found"].exists)
        app.buttons["Cancel Pi run"].firstMatch.tap()
        let confirmation = app.alerts["Cancel Pi's current run?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Keep running"].tap()
    }

    @MainActor
    func testAssistantResponseCanBeCopiedWithoutConnecting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview"]
        app.launch()
        let copy = app.buttons["Copy response"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        if !copy.isHittable { app.swipeUp() }
        copy.tap()
        XCTAssertTrue(app.buttons["Copied response"].exists)
        XCTAssertTrue(app.buttons["Share response"].exists)
        XCTAssertFalse(app.buttons["Send"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Axo dark chat"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
