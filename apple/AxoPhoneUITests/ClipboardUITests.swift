import XCTest

final class ClipboardUITests: XCTestCase {
    @MainActor
    private func paste(into editor: XCUIElement, app: XCUIApplication) {
        editor.press(forDuration: 1.2)
        let item = app.menuItems["Paste"]
        if item.waitForExistence(timeout: 2) { item.tap() }
        else {
            let button = app.buttons["Paste"]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        }
    }

    @MainActor
    func testTextPastePreservesTypedText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-paste-text-preview"]
        app.launch()
        let editor = app.textViews["promptDraft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Typed")
        paste(into: editor, app: app)
        XCTAssertEqual(editor.value as? String, "Typed pasted")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "draftAttachment").firstMatch.exists)
    }

    @MainActor
    func testImagePasteUploadsAnAttachmentWithoutInsertingItsFilename() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-paste-image-preview"]
        app.launch()
        let editor = app.textViews["promptDraft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Keep my image caption")
        paste(into: editor, app: app)
        let card = app.descendants(matching: .any).matching(identifier: "draftAttachment").firstMatch
        let uploaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Uploaded"), object: card)
        let result = XCTWaiter.wait(for: [uploaded], timeout: 10)
        if result != .completed { add(XCTAttachment(string: app.debugDescription)) }
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(editor.value as? String, "Keep my image caption")
        XCTAssertFalse(app.staticTexts["Uploaded · prompt not sent"].exists)
        XCTAssertFalse(app.buttons["Upload files"].exists)
    }

    @MainActor
    func testFilePasteStagesLocalDocumentForReview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-paste-file-preview"]
        app.launch()
        let editor = app.textViews["promptDraft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Keep my file caption")
        paste(into: editor, app: app)
        XCTAssertTrue(app.buttons["Keep drafts without uploading"].waitForExistence(timeout: 10))
        app.buttons["Keep drafts without uploading"].tap()
        XCTAssertTrue(app.buttons["Remove pasted-report.md"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Local draft · not uploaded"].exists)
        XCTAssertEqual(editor.value as? String, "Keep my file caption")
    }

    @MainActor
    func testMultiplePhotosStayTogetherInSelectionOrder() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-photo-collection-preview"]
        app.launch()
        var frames: [CGRect] = []
        for index in 2...4 {
            let photo = app.buttons["shared-file-00000000-0000-4000-8000-00000000000\(index)"]
            let rendered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Photo attachment"), object: photo)
            XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed)
            frames.append(photo.frame)
        }
        XCTAssertLessThan(frames[0].minX, frames[1].minX)
        XCTAssertLessThan(frames[1].minX, frames[2].minX)
        XCTAssertEqual(frames[0].midY, frames[2].midY, accuracy: 1)
        XCTAssertEqual(frames[0].width, 112, accuracy: 1)
        XCTAssertEqual(frames[0].height, 112, accuracy: 1)
    }

    @MainActor
    func testEightPhotoCollectionScrollsToAndOpensLastPhoto() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-photo-collection-preview", "--axo-eight-photo-preview"]
        app.launch()
        let last = app.buttons["shared-file-00000000-0000-4000-8000-000000000009"]
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Photo attachment"), object: last)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed)
        XCTAssertFalse(last.isHittable)
        let row = app.scrollViews["messagePhotoCollection"]
        row.swipeLeft()
        row.swipeLeft()
        XCTAssertTrue(last.isHittable)
        last.tap()
        XCTAssertTrue(app.buttons["Close image preview"].waitForExistence(timeout: 5))
        app.buttons["Close image preview"].tap()
        XCTAssertTrue(app.textViews["promptDraft"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testInvalidPhotoCannotOpenAnEmptyFullScreenPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-inline-photo-preview", "--axo-invalid-photo-preview"]
        app.launch()
        let photo = app.buttons["shared-file-00000000-0000-4000-8000-000000000002"]
        let unavailable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Photo unavailable"), object: photo)
        XCTAssertEqual(XCTWaiter.wait(for: [unavailable], timeout: 10), .completed)
        photo.tap()
        XCTAssertTrue(app.textViews["promptDraft"].exists)
        XCTAssertFalse(app.buttons["Close image preview"].exists)
    }

    @MainActor
    func testSentPhotoRendersInlineAndOpensFullPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-inline-photo-preview"]
        app.launch()
        let photo = app.buttons["shared-file-00000000-0000-4000-8000-000000000002"]
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Photo attachment"), object: photo)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed)
        XCTAssertGreaterThan(photo.frame.height, photo.frame.width * 1.9, "Portrait photos must not be square-cropped")
        XCTAssertGreaterThan(photo.frame.midX, app.frame.midX, "User photos align with the right-hand message")
        XCTAssertFalse(app.staticTexts["draft-photo.png"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Inline photo without a filename card"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        photo.tap()
        XCTAssertTrue(app.buttons["Export original file"].waitForExistence(timeout: 5))
        let zoom = app.scrollViews["photoZoomView"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        XCTAssertEqual(zoom.frame.height, app.frame.height, accuracy: 1, "Preview fills the screen, not a sheet")
        zoom.doubleTap()
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "1.0×"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 3), .completed)
        app.buttons["Photo options"].tap()
        app.buttons["Reset zoom"].tap()
        let fitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1.0×"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [fitted], timeout: 3), .completed)
        app.buttons["Close image preview"].tap()
        XCTAssertTrue(app.textViews["promptDraft"].waitForExistence(timeout: 5))
    }
}
