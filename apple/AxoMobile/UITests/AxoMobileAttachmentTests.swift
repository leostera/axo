import XCTest

final class AxoMobileAttachmentTests: XCTestCase {
  @MainActor private func launch(_ mode: String) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = [
      "AXO_PHONE_PREVIEW": "1", "AXO_MOBILE_PREVIEW_ATTACHMENTS": "1",
      "AXO_MOBILE_PREVIEW_UPLOAD": mode,
    ]
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    XCTAssertTrue(app.buttons["attachment-preview"].firstMatch.waitForExistence(timeout: 15))
    return app
  }

  @MainActor private func wait(_ condition: @escaping () -> Bool) {
    let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
  }

  @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = app.screenshot()
    Snapshots.save(shot.pngRepresentation, named: name)
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor func testPreviewsOverlapWithProgressOnTopAndSelectionRevealsRemove() {
    let app = launch("slow")
    let previews = app.buttons.matching(identifier: "attachment-preview")
    XCTAssertEqual(previews.count, 3)
    let first = app.buttons["first.png"], second = app.buttons["second.png"]
    XCTAssertGreaterThan(first.frame.maxX, second.frame.minX, "a small stack, not filename chips")
    XCTAssertLessThan(first.frame.minX, second.frame.minX)
    XCTAssertEqual(first.frame.width, 80, accuracy: 1)
    XCTAssertFalse(app.staticTexts["first.png"].exists)
    XCTAssertFalse(app.staticTexts["notes.txt"].exists, "ordinary files are preview-only too")
    let spinner = app.descendants(matching: .any).matching(identifier: "attachment-uploading").firstMatch
    XCTAssertTrue(spinner.waitForExistence(timeout: 5))
    XCTAssertTrue(first.frame.contains(spinner.frame), "spinner sits directly over the image")
    XCTAssertFalse(app.buttons["attachment-remove"].exists)
    capture(app, "attachments-uploading-stack")
    first.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)).tap()
    let remove = app.buttons["Remove first.png"]
    XCTAssertTrue(remove.waitForExistence(timeout: 5))
    capture(app, "attachments-selected-remove")
    remove.tapWhereItIs()
    wait { previews.count == 2 }
    XCTAssertFalse(app.buttons["first.png"].exists)
    XCTAssertTrue(app.buttons["second.png"].exists)
  }

  @MainActor func testExhaustedUploadRetriesOnThePreviewAndBecomesReadyWithoutSending() {
    let app = launch("retry")
    let preview = app.buttons["first.png"]
    let retry = app.buttons["attachment-retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 10), "three automatic attempts, then stop")
    XCTAssertTrue(preview.frame.contains(retry.frame), "retry is over the image, not above it")
    XCTAssertTrue((preview.value as? String ?? "").contains("Upload failed"))
    capture(app, "attachments-retry-overlay")
    retry.tapWhereItIs()
    wait { preview.value as? String == "Ready" }
    XCTAssertFalse(retry.exists)
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat", "retrying never creates or sends a chat")
    capture(app, "attachments-ready-stack")
  }
}
