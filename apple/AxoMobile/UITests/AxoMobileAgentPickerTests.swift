import XCTest

final class AxoMobileAgentPickerTests: XCTestCase {
  @MainActor
  func testHostsShowOSMarksAndMacHardware() {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_HOSTS": "1", "AXO_MOBILE_PREVIEW_OS_LOGOS": "1"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Hosts"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.descendants(matching: .any)["host-logo-linux"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["host-logo-windows"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["host-symbol-macstudio"].exists)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "os-and-hardware-logos")
  }

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
