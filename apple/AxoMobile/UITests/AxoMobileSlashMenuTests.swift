import XCTest

final class AxoMobileSlashMenuTests: XCTestCase {
  @MainActor
  func testLongCommandListIsCompactScrollableAndNeverSendsWhenChoosing() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "2", "AXO_PHONE_PREVIEW_LONG_COMMANDS": "1"]
    app.launch()
    let editor = app.textViews["composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 15))
    editor.tapWhereItIs()
    editor.typeText("/")
    let first = app.buttons["slash-command-00"]
    XCTAssertTrue(first.waitForExistence(timeout: 8))
    let menu = app.descendants(matching: .any).matching(identifier: "slash-commands").firstMatch
    XCTAssertLessThanOrEqual(menu.frame.height, 225)
    XCTAssertGreaterThanOrEqual(first.frame.height, 44, "Compact typography must retain a usable touch target")
    Snapshots.save(app.screenshot().pngRepresentation, named: "slash-compact-long-list")
    let last = app.buttons["slash-command-39"]
    for _ in 0..<16 {
      if last.exists && last.isHittable { break }
      menu.swipeUp()
    }
    XCTAssertTrue(last.isHittable, "The last command is reachable without filtering")
    Snapshots.save(app.screenshot().pngRepresentation, named: "slash-scrolled-to-last")
    for _ in 0..<16 {
      if first.exists && first.isHittable { break }
      menu.swipeDown()
    }
    XCTAssertTrue(first.isHittable, "The list also scrolls back up")
    first.tapWhereItIs()
    XCTAssertEqual(editor.value as? String, "/command-00 ")
    XCTAssertFalse(menu.exists)
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "queuedPrompt").count, 0)
  }
}
