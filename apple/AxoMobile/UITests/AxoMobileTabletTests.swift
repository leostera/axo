import XCTest

/// Owned simulator only: no sign-in, device permissions or live Mac commands.
final class AxoMobileTabletTests: XCTestCase {
  @MainActor
  private func wait(_ condition: @escaping () -> Bool) {
    let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
  }

  @MainActor
  func testSidebarPagingAndCollapsePreserveTheConversationAndDraft() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "2"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    wait { title.label == "Fix the sidebar spacing" }
    let sidebar = app.scrollViews["workbench-menu"].firstMatch
    XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    let editor = app.textViews["composer"]
    editor.tapWhereItIs()
    editor.typeText("Keep this iPad draft")
    sidebar.swipeLeft(velocity: .slow)
    let hosts = app.scrollViews["hosts-panel"].firstMatch
    wait { hosts.isHittable }
    XCTAssertEqual(title.label, "Fix the sidebar spacing")
    XCTAssertEqual(editor.value as? String, "Keep this iPad draft")
    XCTAssertTrue(title.isHittable)
    XCTAssertEqual(app.buttons.matching(identifier: "elicitation-bell").count, 1)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-hosts-beside-conversation")
    app.buttons["Back to chats"].tapWhereItIs()
    wait { sidebar.isHittable }
    XCTAssertEqual(editor.value as? String, "Keep this iPad draft")
    app.buttons["Toggle sidebar"].tapWhereItIs()
    wait { !sidebar.isHittable }
    XCTAssertEqual(editor.value as? String, "Keep this iPad draft")
    XCTAssertLessThanOrEqual(editor.frame.width, 800)
    let rows = app.collectionViews["conversation-list"].cells.allElementsBoundByIndex.filter { $0.frame.height > 5 }
    XCTAssertFalse(rows.isEmpty)
    for row in rows { XCTAssertLessThanOrEqual(row.frame.width, 761) }
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-readable-detail")
    app.buttons["Toggle sidebar"].tapWhereItIs()
    wait { sidebar.isHittable }
    XCTAssertEqual(editor.value as? String, "Keep this iPad draft")
  }

  @MainActor
  func testSettingsAreAContainedDirectoryWithNativeSubpages() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_SETTINGS": "1"]
    app.launch()
    let home = app.scrollViews["settings-home"].firstMatch
    XCTAssertTrue(home.waitForExistence(timeout: 20))
    XCTAssertLessThan(home.frame.width, app.windows.firstMatch.frame.width)
    XCTAssertTrue(app.buttons["settings-account"].exists)
    XCTAssertTrue(app.buttons["settings-apps"].exists)
    XCTAssertTrue(app.buttons["settings-chats"].exists)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-settings-home")
    app.buttons["settings-appearance"].tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Accent color"].exists)
    XCTAssertTrue(app.buttons["appearance-picker"].exists)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-settings-appearance")
    app.navigationBars.buttons["Settings"].tapWhereItIs()
    app.buttons["Close settings"].tapWhereItIs()
    XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSidebarAndConversationStayTogetherAcrossRotationAndNewChat() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "3"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    let sidebar = app.scrollViews["workbench-menu"].firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
    XCTAssertTrue(sidebar.isHittable)
    XCTAssertLessThan(sidebar.frame.width, app.windows.firstMatch.frame.width / 2)

    let opened = NSPredicate(format: "label != %@", "New chat")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: opened, object: title)], timeout: 10), .completed)
    let selected = title.label
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    XCTAssertEqual(title.label, selected)
    XCTAssertTrue(sidebar.isHittable)

    app.buttons["New chat"].tap()
    let blank = NSPredicate(format: "label == %@", "New chat")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: blank, object: title)], timeout: 5), .completed)
    XCTAssertTrue(sidebar.isHittable, "Choosing a conversation must not dismiss the iPad sidebar")
    let welcome = app.staticTexts["What are we working on?"]
    XCTAssertTrue(welcome.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(welcome.frame.minX, sidebar.frame.maxX, "The transcript must not extend beneath the sidebar")
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "axo-mobile-ipad"
    attachment.lifetime = .keepAlways
    add(attachment)
    Snapshots.save(screenshot.pngRepresentation, named: "axo-mobile-ipad")
    let editor = app.textViews["composer"]
    let compactWidth = editor.frame.width
    editor.tapWhereItIs()
    let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      editor.frame.width > compactWidth && app.buttons["attach"].frame.minY >= editor.frame.maxY
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 8), .completed)
    XCTAssertGreaterThanOrEqual(editor.frame.minX, sidebar.frame.maxX)
    XCTAssertTrue(sidebar.isHittable)
    Snapshots.save(app.screenshot().pngRepresentation, named: "axo-mobile-ipad-composer-focused")
  }
}
