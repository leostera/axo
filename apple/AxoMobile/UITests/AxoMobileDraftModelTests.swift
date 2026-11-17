import XCTest

final class AxoMobileDraftModelTests: XCTestCase {
  @MainActor
  func testNewDraftChoosesModelAndThinkingWithoutSendingOrCreatingAChat() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1"]
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    let editor = app.textViews["composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 15))
    editor.tapWhereItIs()
    let picker = app.buttons["model-picker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    XCTAssertEqual(picker.label, "Model: Host default")
    picker.tapWhereItIs()
    let model = app.buttons["model-gpt-5"]
    XCTAssertTrue(model.waitForExistence(timeout: 5))
    model.tapWhereItIs()
    XCTAssertEqual(picker.label, "Model: GPT-5 · Minimal")
    editor.tapWhereItIs()
    picker.tapWhereItIs()
    let high = app.buttons["thinking-high"]
    XCTAssertTrue(high.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["thinking-xhigh"].exists)
    high.tapWhereItIs()
    XCTAssertEqual(picker.label, "Model: GPT-5 · High")
    editor.tapWhereItIs()
    editor.typeText("Keep this first message")
    XCTAssertEqual(editor.value as? String, "Keep this first message")
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat")
    Snapshots.save(app.screenshot().pngRepresentation, named: "new-chat-model-thinking")
    picker.tapWhereItIs()
    let defaults = app.buttons["model-host-default"]
    XCTAssertTrue(defaults.waitForExistence(timeout: 5))
    defaults.tapWhereItIs()
    XCTAssertEqual(picker.label, "Model: Host default")
    XCTAssertEqual(editor.value as? String, "Keep this first message")
  }
}
