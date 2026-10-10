import XCTest

final class ChatLayoutUITests: XCTestCase {
    @MainActor
    func testConnectionInternalsAreNotExposedInChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview"]
        app.launch()
        let sessionMenu = app.buttons["Sessions menu"]
        XCTAssertTrue(sessionMenu.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Write a message"].exists)
        XCTAssertFalse(app.buttons["Chat options"].exists)
        XCTAssertFalse(app.textFields["relayEndpoint"].exists)
        sessionMenu.tap()
        XCTAssertFalse(app.buttons["Connection settings"].exists)
        XCTAssertFalse(app.buttons["Reconnect"].exists)
        XCTAssertTrue(app.buttons["Composer options"].exists)
    }

    @MainActor
    func testComposerStartsWithActionsBesideSingleLineInput() throws {
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
        XCTAssertEqual(options.frame.midY, input.frame.midY, accuracy: 8)
        XCTAssertEqual(voice.frame.midY, input.frame.midY, accuracy: 8)
    }

    @MainActor
    func testComposerReflowsWhenTextWrapsAndCanExpandToFullScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview"]
        app.launch()

        let input = app.descendants(matching: .any).matching(identifier: "promptDraft").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(String(repeating: "A", count: 80))

        let expander = app.buttons["expandComposer"]
        XCTAssertTrue(expander.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.buttons["Composer options"].frame.midY, input.frame.midY)
        XCTAssertGreaterThan(app.buttons["voicePromptButton"].frame.midY, input.frame.midY)

        expander.tap()
        XCTAssertTrue(app.navigationBars["Message Axo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["expanded-composer"].exists)
        app.buttons["Done"].tap()
    }

    @MainActor
    func testRunningPreviewShowsThinkingAndToolActivity() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview-working"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Pi is calling tools…"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Synthetic provider thinking text for the chat preview."].exists)
        XCTAssertTrue(app.staticTexts["Bash"].exists)
        XCTAssertTrue(app.staticTexts["$ npm test"].exists)
        XCTAssertFalse(app.staticTexts["completed"].exists)
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
