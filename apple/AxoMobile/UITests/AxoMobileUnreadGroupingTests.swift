import XCTest

final class AxoMobileUnreadGroupingTests: XCTestCase {
  @MainActor
  func testUnreadEarlierChatsStayInEarlierAfterMarkAllRead() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_UNSEEN": "1", "AXO_PHONE_PREVIEW_MENU": "1"]
    app.launch()
    let earlier = app.buttons["chat-group-earlier"]
    XCTAssertTrue(earlier.waitForExistence(timeout: 15))
    let names = ["Plan the week", "Fix the sidebar spacing", "Explain the relay", "Draft the release notes"]
    let rows = names.map { app.buttons[$0] }
    for row in rows {
      XCTAssertTrue(row.exists)
      XCTAssertLessThan(earlier.frame.minY, row.frame.minY, "Unread old chats belong in Earlier")
      XCTAssertTrue((row.value as? String)?.contains("Unseen") == true)
    }
    let before = rows.map { $0.frame.minY }
    let markAll = app.buttons["mark-all-read"]
    XCTAssertTrue(markAll.exists)
    markAll.tapWhereItIs()
    XCTAssertTrue(markAll.waitForNonExistence(timeout: 5))
    for (index, row) in rows.enumerated() {
      XCTAssertFalse((row.value as? String)?.contains("Unseen") == true)
      XCTAssertEqual(row.frame.minY, before[index], accuracy: 1, "Reading must not move rows")
    }
  }
}
