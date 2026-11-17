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
    let detailX = title.frame.minX
    sidebar.swipeRight(velocity: .slow)
    let hosts = app.scrollViews["hosts-panel"].firstMatch
    wait { hosts.isHittable }
    XCTAssertEqual(title.label, "Fix the sidebar spacing")
    XCTAssertEqual(editor.value as? String, "Keep this iPad draft")
    XCTAssertTrue(title.isHittable)
    XCTAssertEqual(title.frame.minX, detailX, accuracy: 1)
    XCTAssertEqual(app.buttons.matching(identifier: "elicitation-bell").count, 1)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-hosts-beside-conversation")
    hosts.swipeLeft(velocity: .slow)
    wait { sidebar.isHittable }
    XCTAssertEqual(editor.value as? String, "Keep this iPad draft")
    sidebar.swipeRight(velocity: .slow)
    wait { hosts.isHittable }
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
  func testAppsReplacesDetailAndReturningKeepsTheConversationDraft() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "2"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    wait { title.label == "Fix the sidebar spacing" }
    let editor = app.textViews["composer"]
    editor.tapWhereItIs()
    editor.typeText("Keep this Apps draft")
    let sidebar = app.scrollViews["workbench-menu"].firstMatch
    sidebar.swipeRight(velocity: .slow)
    let hosts = app.scrollViews["hosts-panel"].firstMatch
    wait { hosts.isHittable }
    hosts.swipeUp()
    app.buttons["Apps"].tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 10))
    XCTAssertFalse(editor.isHittable)
    XCTAssertEqual(app.sheets.count, 0)
    XCTAssertTrue(hosts.isHittable)
    XCTAssertEqual(app.buttons.matching(identifier: "elicitation-bell").count, 1)
    let gmail = app.buttons["Gmail"]
    XCTAssertTrue(gmail.waitForExistence(timeout: 10))
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-apps-detail")
    XCTAssertTrue(gmail.isHittable)
    XCTAssertGreaterThanOrEqual(gmail.frame.minX, hosts.frame.maxX)
    gmail.tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Gmail"].waitForExistence(timeout: 5))
    app.navigationBars.buttons["Apps"].tapWhereItIs()
    app.buttons["Back to conversation"].tapWhereItIs()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "Keep this Apps draft")
    XCTAssertEqual(title.label, "Fix the sidebar spacing")

    app.buttons["Apps"].tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 5))
    app.buttons["Back to chats"].tapWhereItIs()
    let selected = sidebar.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fix the sidebar spacing")).firstMatch
    selected.tapWhereItIs()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "Keep this Apps draft")
  }

  @MainActor
  func testChatInfoIsATrailingPaneAndKeepsTheComposerInteractive() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "2"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    wait { title.label == "Fix the sidebar spacing" }
    let editor = app.textViews["composer"]
    editor.tapWhereItIs()
    editor.typeText("Keep this info draft")
    app.buttons["Chat info"].tapWhereItIs()
    let info = app.scrollViews["session-info"].firstMatch
    wait { info.isHittable }
    XCTAssertEqual(app.sheets.count, 0)
    XCTAssertTrue(editor.isHittable)
    XCTAssertGreaterThanOrEqual(info.frame.minX, editor.frame.maxX)
    editor.typeText(" and keep typing")
    XCTAssertEqual(editor.value as? String, "Keep this info draft and keep typing")
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-chat-info-pane")
    app.buttons["Close chat info"].tapWhereItIs()
    wait { !info.isHittable }
    XCTAssertEqual(editor.value as? String, "Keep this info draft and keep typing")
  }

  @MainActor
  func testSettingsAppsOpensTheWorkbenchDetailInsteadOfAnotherModalPage() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_SETTINGS": "1"]
    app.launch()
    XCTAssertTrue(app.buttons["settings-apps"].waitForExistence(timeout: 20))
    app.buttons["settings-apps"].tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.sheets.count, 0)
    XCTAssertTrue(app.buttons["Back to conversation"].exists)
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
