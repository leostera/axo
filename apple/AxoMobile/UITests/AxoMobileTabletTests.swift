import XCTest

/// Owned simulator only: no sign-in, device permissions or live Mac commands.
final class AxoMobileTabletTests: XCTestCase {
  @MainActor
  private func wait(_ condition: @escaping () -> Bool) {
    let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
  }

  @MainActor
  func testSidebarBackgroundCoversTopAndBottomSafeAreasOnBothPages() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    for appearance in ["light", "dark"] {
      let app = XCUIApplication()
      app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "2"]
      app.launchArguments = ["-appearance", appearance]
      app.launch()
      let sidebar = app.scrollViews["workbench-menu"].firstMatch
      XCTAssertTrue(sidebar.waitForExistence(timeout: 20))
      assertFooterInsets(in: app, container: sidebar, leading: "New chat")
      Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-sidebar-\(appearance)-full-bleed")
      assertSidebarSafeAreaBackground(sidebar, in: app, dark: appearance == "dark")
      sidebar.swipeRight(velocity: .slow)
      let hosts = app.scrollViews["hosts-panel"].firstMatch
      wait { hosts.isHittable }
      assertFooterInsets(in: app, container: hosts, leading: "Pair a Mac")
      assertSidebarSafeAreaBackground(hosts, in: app, dark: appearance == "dark")
      app.terminate()
    }
  }

  @MainActor
  private func assertFooterInsets(in app: XCUIApplication, container: XCUIElement, leading: String) {
    let first = app.buttons.matching(identifier: leading).allElementsBoundByIndex.first { $0.isHittable }
    let last = app.buttons.matching(identifier: "Settings").allElementsBoundByIndex.first { $0.isHittable }
    XCTAssertNotNil(first)
    XCTAssertNotNil(last)
    guard let first, let last else { return }
    XCTAssertLessThanOrEqual(first.frame.minX - container.frame.minX, 16)
    XCTAssertLessThanOrEqual(container.frame.maxX - last.frame.maxX, 16)
    XCTAssertGreaterThanOrEqual(last.frame.height, 44)
  }

  @MainActor
  private func assertSidebarSafeAreaBackground(_ sidebar: XCUIElement, in app: XCUIApplication, dark: Bool) {
    let screenshot = XCUIScreen.main.screenshot()
    guard let image = screenshot.image.cgImage else { return XCTFail("Missing screenshot") }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    XCTAssertTrue(drawn)
    // Portrait avoids XCTest's landscape bitmap orientation issue. Stay clear of system text,
    // window corners and the detail pane's home indicator.
    let scale = Double(width) / app.windows.firstMatch.frame.width
    let x = Int(sidebar.frame.midX * scale)
    for y in [4, height - 5] {
      let offset = (y * width + x) * 4
      let rgb = pixels[offset..<(offset + 3)]
      // Allow the native floating-column shadow at the extreme bottom edge, not a solid grey band.
      XCTAssertTrue(rgb.allSatisfy { dark ? $0 < 30 : $0 > 240 },
        "Sidebar safe areas must match its background, not leak grey navigation chrome: dark=\(dark) x=\(x) y=\(y) rgb=\(Array(rgb))")
    }
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
  func testAppsUsesCardsWithSearchStatusAndCategoryFilters() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_APPS": "1"]
    app.launch()
    let gmail = app.buttons["Gmail"]
    let passwords = app.buttons["1Password"]
    XCTAssertTrue(gmail.waitForExistence(timeout: 20))
    XCTAssertTrue(passwords.exists)
    XCTAssertEqual(gmail.frame.minY, passwords.frame.minY, accuracy: 2)
    XCTAssertGreaterThanOrEqual(passwords.frame.minX, gmail.frame.maxX + 10)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-apps-grid")
    let search = app.textFields["apps-grid-search"]
    search.tapWhereItIs()
    search.typeText("Google\n")
    XCTAssertTrue(gmail.exists)
    XCTAssertTrue(app.buttons["Calendar"].exists, "Search includes the provider as on the web")
    app.buttons["apps-status-notConnected"].tapWhereItIs()
    wait { !gmail.exists }
    XCTAssertTrue(app.buttons["Calendar"].exists)
    app.buttons["apps-category-productivity"].tapWhereItIs()
    XCTAssertTrue(app.buttons["Calendar"].exists)
    app.buttons["apps-category-communication"].tapWhereItIs()
    XCTAssertTrue(app.staticTexts["No apps match"].exists)
    app.buttons["apps-status-all"].tapWhereItIs()
    XCTAssertTrue(gmail.exists)
    Snapshots.save(XCUIScreen.main.screenshot().pngRepresentation, named: "ipad-apps-filtered")
    gmail.tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Gmail"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.sheets.count, 0)
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
