import XCTest

final class AxoMobileIdentityMigrationTests: XCTestCase {
  @MainActor
  func testDestinationProbeCannotFallThroughToAccountOrComposerEvenWithInvalidMode() {
    continueAfterFailure = false
    for mode in ["destination", "invalid-mode"] {
      let app = XCUIApplication()
      app.launchEnvironment = [
        "AXO_PHONE_PREVIEW": "1",
        "AXO_PHONE_PREVIEW_CHAT": "1",
        "AXO_IDENTITY_PROBE_MODE": mode,
        "AXO_IDENTITY_PROBE_RUN_ID": UUID().uuidString,
      ]
      app.launch()
      let status = app.staticTexts["identity-preservation-status"]
      XCTAssertTrue(status.waitForExistence(timeout: 15))
      XCTAssertEqual(status.label, "The preservation configuration could not be verified.")
      XCTAssertFalse(app.textViews["composer"].exists)
      XCTAssertFalse(app.staticTexts["conversation-title"].exists)
      XCTAssertTrue(app.staticTexts["Sign-in migration is not complete. Keep the previous Axo app installed."].exists)
      app.buttons["identity-preservation-retry"].tap()
      XCTAssertEqual(status.label, "The preservation configuration could not be verified.")
      app.terminate()
    }
  }
}
