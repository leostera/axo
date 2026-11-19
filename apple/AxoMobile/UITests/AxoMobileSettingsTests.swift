import XCTest

final class AxoMobileSettingsTests: XCTestCase {
  @MainActor private func launch(_ appearance: String) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_SETTINGS": "1"]
    app.launchArguments = ["-appearance", appearance]
    app.launch()
    XCTAssertTrue(app.scrollViews["settings-home"].waitForExistence(timeout: 20))
    return app
  }

  @MainActor
  func testSignedInProfileDoesNotRequireDeviceEnrollment() {
    let app = launch("light")
    app.buttons["settings-account"].tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["link-device"].exists)
    XCTAssertFalse(app.buttons["show-link-code"].exists)
    XCTAssertFalse(app.staticTexts["Waiting for approval on your existing phone"].exists)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "profile-without-enrollment")
  }

  @MainActor
  func testRichNotificationPreviewsAreAnExplicitPreference() {
    let app = launch("light")
    app.buttons["settings-notifications"].tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
    let toggle = app.switches["notification-rich-previews"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    let before = toggle.value as? String
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "settings-notifications")
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertTrue(NSPredicate(format: "value != %@", before ?? "0").evaluate(with: toggle))
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Sensitive input always opens Axo")).firstMatch.exists)
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertEqual(toggle.value as? String, before)
  }

  @MainActor
  func testAppearanceHasVisibleLabelsAndTrailingPickers() {
    let app = launch("light")
    app.buttons["settings-appearance"].tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    let label = app.staticTexts["Accent color"]
    let picker = app.buttons["accent-picker"]
    XCTAssertTrue(label.exists)
    XCTAssertTrue(picker.exists)
    XCTAssertLessThan(label.frame.maxX, picker.frame.minX)
    XCTAssertTrue(app.buttons["appearance-picker"].exists)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "settings-appearance")
  }

  @MainActor
  func testDarkSettingsKeepsRealDestinationsAndSignOutNeedsConfirmation() {
    let app = launch("dark")
    for name in ["account", "apps", "appearance", "chats"] {
      XCTAssertTrue(app.buttons["settings-\(name)"].exists)
    }
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "settings-home-dark")
    app.buttons["Sign out"].tapWhereItIs()
    let cancel = app.buttons["Cancel"].firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    cancel.tapWhereItIs()
    XCTAssertTrue(app.scrollViews["settings-home"].exists, "Cancel retains this device's sign-in")
    app.buttons["Close settings"].tapWhereItIs()
    XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 5))
  }
}
