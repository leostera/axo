import XCTest

final class AxoMobileAgentPickerTests: XCTestCase {
  @MainActor
  func testOnlyAvailableAgentsAppearWithTheirMarks() {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1"]
    app.launch()
    let picker = app.buttons["agent-picker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 20))
    picker.tapWhereItIs()
    XCTAssertTrue(app.buttons["Codex"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Claude Code"].exists)
    XCTAssertFalse(app.buttons["OpenCode"].exists)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "available-agent-logos")
    app.buttons["Codex"].firstMatch.tapWhereItIs()
    XCTAssertTrue(app.buttons["Agent: Codex"].waitForExistence(timeout: 5))
  }
}
