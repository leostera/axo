import XCTest

final class AxoMobileIdentityMigrationTests: XCTestCase {
  @MainActor
  func testCredentialTransferStaysExclusiveWithoutASourceOrWithInvalidConfiguration() {
    continueAfterFailure = false
    for mode in ["destination", "invalid-mode"] {
      let app = XCUIApplication()
      app.launchEnvironment = [
        "AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "1",
        "AXO_IDENTITY_MIGRATION_MODE": mode,
        "AXO_IDENTITY_MIGRATION_ACCESS_GROUP": "TESTTEAM01.dev.leostera.axo.migration",
        "AXO_IDENTITY_MIGRATION_SCOPE": "mobile-only",
      ]
      app.launch()
      XCTAssertTrue(app.staticTexts["Keep your Axo sign-in"].waitForExistence(timeout: 15))
      XCTAssertFalse(app.textViews["composer"].exists)
      XCTAssertFalse(app.staticTexts["conversation-title"].exists)
      XCTAssertTrue(app.buttons["Check transfer"].waitForExistence(timeout: 15))
      app.buttons["Check transfer"].tap()
      XCTAssertTrue(app.staticTexts["Keep your Axo sign-in"].exists)
      XCTAssertFalse(app.textViews["composer"].exists)
      app.terminate()
    }
  }

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
