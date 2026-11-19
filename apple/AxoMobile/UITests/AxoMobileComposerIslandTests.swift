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
  private func leaveAndReturn(_ app: XCUIApplication) {
    if app.buttons["Chats menu"].exists {
      app.buttons["Chats menu"].tapWhereItIs()
      app.buttons["Back to conversation"].tapWhereItIs()
    } else {
      // iPad keeps the conversation mounted while its sidebar is toggled.
      app.buttons["Toggle sidebar"].tapWhereItIs()
      app.buttons["Toggle sidebar"].tapWhereItIs()
    }
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
  func testSelectorsKeepOneStableToolbarBeforeAndAfterFocus() {
    let app = launch()
    let editor = app.textViews["composer"]
    let add = app.buttons["attach"]
    let send = app.buttons["send-message"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    let width = editor.frame.width
    XCTAssertGreaterThanOrEqual(add.frame.minY, editor.frame.maxY)
    XCTAssertEqual(add.frame.midY, send.frame.midY, accuracy: 4)
    XCTAssertTrue(app.buttons["model-picker"].exists)
    XCTAssertTrue(app.buttons["thinking-picker"].exists)
    capture(app, "composer-selectors-resting")

    editor.tapWhereItIs()
    wait("Focus preserves the editor width and the toolbar row") {
      add.frame.minY >= editor.frame.maxY && abs(editor.frame.width - width) < 2
    }
    capture(app, "composer-selectors-focused")
    leaveAndReturn(app)
    wait("The selectors remain available without expanding or collapsing the editor") {
      add.frame.minY >= editor.frame.maxY && abs(editor.frame.width - width) < 2
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
    leaveAndReturn(app)
    wait("A saved draft stays expanded, with no automatic send") {
      app.buttons["attach"].frame.minY >= editor.frame.maxY
    }
    XCTAssertEqual(editor.value as? String, text)
    XCTAssertTrue(app.buttons["send-message"].isEnabled)
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "queuedPrompt").count, 0)
    capture(app, "composer-island-retained-draft")
  }
}
