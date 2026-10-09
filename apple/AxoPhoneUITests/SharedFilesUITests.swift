import XCTest

final class SharedFilesUITests: XCTestCase {
    @MainActor
    func testBackToBottomIsVisibleWhileReadingOlderMessagesAndReturnsDirectly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-history-preview"]
        app.launch()
        let latest = app.staticTexts["LATEST MESSAGE"]
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        let scroll = app.scrollViews.firstMatch
        scroll.swipeDown()
        let button = app.buttons["back-to-bottom"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        XCTAssertTrue(latest.isHittable)
        let disappeared = NSPredicate(format: "exists == false")
        expectation(for: disappeared, evaluatedWith: button)
        waitForExpectations(timeout: 3)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Back to newest message"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPublicationConsentCanBeDeclinedWithoutLosingTheLocalDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-file-draft-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Local draft · not uploaded"].waitForExistence(timeout: 10))
        app.buttons["Review/upload"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'not end-to-end encrypted'")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Keep drafts without uploading"].tap()
        XCTAssertTrue(app.staticTexts["Local draft · not uploaded"].exists)
        XCTAssertFalse(app.buttons["sendPromptButton"].isEnabled)
    }

    @MainActor
    func testConfirmedUploadRemainsUnsentAndItsMarkdownOpensWithoutAMac() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-file-draft-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["Review/upload"].waitForExistence(timeout: 10))
        app.buttons["Review/upload"].tap()
        app.buttons["Upload files"].tap()
        XCTAssertTrue(app.staticTexts["Uploaded · prompt not sent"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sendPromptButton"].isEnabled)
        app.buttons["Composer options"].tap()
        app.buttons["Session files"].tap()
        let card = app.buttons["shared-file-00000000-0000-4000-8000-000000000002"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.staticTexts["Synthetic shared report"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Verified Markdown file preview without a Mac"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFileCardAndExplicitComposerActionsDoNotRequireAConnection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-files-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["report.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Discuss this shared report"].exists)
        app.buttons["Composer options"].tap()
        XCTAssertTrue(app.buttons["Attach document"].exists)
        XCTAssertTrue(app.buttons["Attach photo as JPEG (2048px)"].exists)
        XCTAssertTrue(app.buttons["Session files"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shared file card and input actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
