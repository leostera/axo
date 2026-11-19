import XCTest

final class AxoMobileDraftPreservationTests: XCTestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_MOBILE_PREVIEW_SECOND_HOST_ONLINE": "1"]
    app.launch()
    XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 15))
    return app
  }

  @MainActor
  private func changeHostAndAgent(_ app: XCUIApplication) {
    let host = app.buttons["host-picker"]
    let previous = host.label
    let target = previous.contains("Old iMac") ? "Studio" : "Old iMac"
    host.tapWhereItIs()
    let candidates = app.buttons.matching(identifier: target)
    let visible = NSPredicate { _, _ in candidates.allElementsBoundByIndex.contains { $0.isHittable } }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: app)], timeout: 5), .completed)
    // Hidden account layers also contain host buttons; only the visible menu item is a choice.
    guard let other = candidates.allElementsBoundByIndex.first(where: { $0.isHittable }) else { return XCTFail("No visible host choice") }
    Snapshots.save(app.screenshot().pngRepresentation, named: "draft-host-menu")
    other.tapWhereItIs()
    let changed = NSPredicate { _, _ in host.label.contains(target) }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: host)], timeout: 5), .completed,
      "Host choice: before=\(previous), target=\(target), after=\(host.label)")
    XCTAssertNotEqual(host.label, previous, "The test must actually change the host")
    let agent = app.buttons["agent-picker"]
    XCTAssertTrue(agent.waitForExistence(timeout: 5))
    agent.tapWhereItIs()
    let codex = app.buttons["Codex"].firstMatch
    XCTAssertTrue(codex.waitForExistence(timeout: 5))
    codex.tapWhereItIs()
    XCTAssertTrue(app.buttons["Agent: Codex"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testTypedNewChatDraftSurvivesHostAndAgentChanges() {
    let app = launch()
    let editor = app.textViews["composer"]
    editor.tapWhereItIs()
    editor.typeText("Keep this new-session message")
    changeHostAndAgent(app)
    XCTAssertEqual(editor.value as? String, "Keep this new-session message")
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat")
  }

  @MainActor
  func testRecordingContinuesAcrossHostAndAgentChangesAndKeepsTypedPrefix() {
    let app = launch()
    let editor = app.textViews["composer"]
    editor.tapWhereItIs()
    editor.typeText("Typed prefix")
    app.buttons["voice-start"].tapWhereItIs()
    let heard = app.staticTexts["voice-heard"]
    XCTAssertTrue(heard.waitForExistence(timeout: 5))
    let complete = NSPredicate(format: "label == %@", "Make the tests pass")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: complete, object: heard)], timeout: 8), .completed)
    changeHostAndAgent(app)
    XCTAssertTrue(app.buttons["voice-stop"].exists, "Changing execution options must not stop the recording")
    app.buttons["voice-stop"].tapWhereItIs()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "Typed prefix Make the tests pass")
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat", "No chat is created or message sent")
    Snapshots.save(app.screenshot().pngRepresentation, named: "draft-after-host-and-agent-change")
  }
}
