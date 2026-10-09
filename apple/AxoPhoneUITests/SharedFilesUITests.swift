import XCTest

final class SharedFilesUITests: XCTestCase {
    @MainActor
    private func waitForUploadedAttachment(_ app: XCUIApplication) {
        let card = app.descendants(matching: .any).matching(identifier: "draftAttachment").firstMatch
        let uploaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Uploaded"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [uploaded], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["Uploaded · prompt not sent"].exists)
    }

    @MainActor
    func testPhotoSelectionUploadsWithoutRepeatedConfirmationAndShowsComposerThumbnail() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-photo-draft-preview"]
        app.launch()
        waitForUploadedAttachment(app)
        XCTAssertTrue(app.buttons["Preview draft-photo.png"].exists)
        XCTAssertTrue(app.buttons["Remove draft-photo.png"].exists)
        XCTAssertFalse(app.buttons["Upload files"].exists)
        XCTAssertFalse(app.buttons["Keep drafts without uploading"].exists)
        app.buttons["Remove draft-photo.png"].tap()
        XCTAssertFalse(app.buttons["Preview draft-photo.png"].exists)
    }

    @MainActor
    func testDraftPhotoOpensFullScreenAndCanBeRemovedWithoutSending() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-photo-draft-preview"]
        app.launch()
        waitForUploadedAttachment(app)
        app.buttons["Preview draft-photo.png"].tap()
        XCTAssertTrue(app.buttons["Close image preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Export original file"].exists)
        app.buttons["Photo options"].tap()
        app.buttons["Remove attachment from draft"].tap()
        XCTAssertTrue(app.textViews["promptDraft"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Preview draft-photo.png"].exists)
    }

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
        XCTAssertEqual(button.label, "Jump to latest")
        XCTAssertLessThan(button.frame.maxY, app.textViews["promptDraft"].frame.minY)
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
        waitForUploadedAttachment(app)
        XCTAssertFalse(app.buttons["sendPromptButton"].isEnabled)
        app.buttons["Chat options"].tap()
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
    func testCameraPermissionDenialPreservesTheDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-photo-draft-preview"]
        app.resetAuthorizationStatus(for: .camera)
        app.launch()
        waitForUploadedAttachment(app)
        let draft = app.descendants(matching: .any).matching(identifier: "promptDraft").firstMatch
        draft.tap()
        draft.typeText("Keep camera draft")
        app.buttons["Composer options"].tap()
        let camera = app.buttons["attachCamera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertTrue(camera.isEnabled)
        camera.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = system.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label != %@", "Allow", "Allow")).firstMatch
        if deny.waitForExistence(timeout: 3) { deny.tap() }
        let refusal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Camera ")).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Keep camera draft")
    }

    @MainActor
    func testFileCardAndExplicitComposerActionsDoNotRequireAConnection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-files-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["report.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Discuss this shared report"].exists)
        app.buttons["Composer options"].tap()
        XCTAssertTrue(app.buttons["Camera"].exists)
        XCTAssertTrue(app.buttons["Photos"].exists)
        XCTAssertTrue(app.buttons["Files"].exists)
        XCTAssertFalse(app.buttons["Session files"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Connection settings")).count, 0, "Connection settings is not part of the composer menu")
        XCTAssertFalse(app.buttons["Paste text at end"].exists)
        XCTAssertFalse(app.buttons["About voice"].exists)
        XCTAssertFalse(app.staticTexts["Selected photos upload to private cloud storage as JPEG (2048px). Not end-to-end encrypted."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shared file card and input actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
