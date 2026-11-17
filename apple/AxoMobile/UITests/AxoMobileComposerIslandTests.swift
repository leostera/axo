import XCTest

final class AxoMobileComposerIslandTests: XCTestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "2"]
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    let ready = NSPredicate(format: "label == %@", "Fix the sidebar spacing")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: title)], timeout: 10), .completed)
    return app
  }

  @MainActor
  private func wait(_ description: String, _ predicate: @escaping () -> Bool) {
    let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed, description)
  }

  @MainActor
  private func capture(_ app: XCUIApplication, _ name: String) {
    let screenshot = app.screenshot()
    Snapshots.save(screenshot.pngRepresentation, named: name)
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testEmptyIslandExpandsOnFocusAndCollapsesAfterLeavingAnEmptyEditor() {
    let app = launch()
    let editor = app.textViews["composer"]
    let add = app.buttons["attach"]
    let send = app.buttons["send-message"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    let compactWidth = editor.frame.width
    XCTAssertLessThan(abs(add.frame.midY - editor.frame.midY), 8)
    XCTAssertLessThan(abs(send.frame.midY - editor.frame.midY), 8)
    XCTAssertFalse(app.buttons["model-picker"].exists)
    capture(app, "composer-island-resting")

    editor.tapWhereItIs()
    wait("Focus expands into two rows without replacing the editor") {
      add.frame.minY >= editor.frame.maxY && editor.frame.width > compactWidth
    }
    XCTAssertTrue(app.buttons["model-picker"].exists)
    capture(app, "composer-island-focused")
    app.buttons["Chats menu"].tapWhereItIs()
    app.buttons["Back to conversation"].tapWhereItIs()
    wait("An empty, unfocused editor returns to the small island") {
      abs(add.frame.midY - editor.frame.midY) < 8 && abs(editor.frame.width - compactWidth) < 2
    }
    XCTAssertEqual(editor.value as? String ?? "", "")
  }

  @MainActor
  func testDraftAndFocusSurviveExpansionAndReturningToTheChat() {
    let app = launch()
    let editor = app.textViews["composer"]
    editor.tapWhereItIs()
    let text = "Keep this draft\nwith two lines"
    editor.typeText(text)
    XCTAssertEqual(editor.value as? String, text)
    app.buttons["Chats menu"].tapWhereItIs()
    app.buttons["Back to conversation"].tapWhereItIs()
    wait("A saved draft stays expanded, with no automatic send") {
      app.buttons["attach"].frame.minY >= editor.frame.maxY
    }
    XCTAssertEqual(editor.value as? String, text)
    XCTAssertTrue(app.buttons["send-message"].isEnabled)
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "queuedPrompt").count, 0)
    capture(app, "composer-island-retained-draft")
  }
}
