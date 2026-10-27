import XCTest

/// What the screen redraws while the person does something, counted by the app itself
/// (`AXO_PHONE_PREVIEW_RENDERS=1`). Each test does one thing and checks that only the views that
/// show it ran their `body` again: work the screen does for nothing is work a frame waits on.
final class AxoPhoneRenderTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_RENDERS": "1"].merging(environment) { $1 }
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    XCTAssertTrue(app.staticTexts["conversation-title"].waitForExistence(timeout: 15))
    return app
  }

  /// The counts once they have stopped changing.
  @MainActor
  private func counts(_ app: XCUIApplication) -> [String: Int] {
    let label = app.staticTexts["render-counts"]
    XCTAssertTrue(label.waitForExistence(timeout: 5))
    var last = ""
    for _ in 0..<20 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      let now = label.label
      if now == last { break }
      last = now
    }
    return Dictionary(uniqueKeysWithValues: last.split(separator: " ").compactMap { pair in
      let parts = pair.split(separator: "=")
      guard parts.count == 2, let count = Int(parts[1]) else { return nil }
      return (String(parts[0]), count)
    })
  }

  /// Waits until `element` can be tapped: on the layer showing, and settled.
  private func hittable(_ element: XCUIElement) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      // Every layer stays in the tree UI tests read; on the left edge means its layer shows.
      if element.exists, element.frame.minX >= 0, element.frame.minX < 60 { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }

  private func delta(_ before: [String: Int], _ after: [String: Int]) -> [String: Int] {
    after.reduce(into: [:]) { result, entry in result[entry.key] = entry.value - before[entry.key, default: 0] }
  }

  @MainActor
  func testDraggingTheMenuDoesNotRedrawTheConversation() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2"])
    XCTAssertTrue(app.staticTexts["Fix the sidebar spacing"].waitForExistence(timeout: 5))
    let before = counts(app)
    for _ in 0..<3 {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
      start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
      XCTAssertTrue(hittable(app.buttons["New chat"]))
      let back = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
      back.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
      XCTAssertTrue(hittable(app.buttons["Chats menu"]))
    }
    let moved = delta(before, counts(app))
    print("RENDERS drag menu x3:", moved.sorted { $0.key < $1.key })
    // Only the sliding follows the finger; what slides redraws once as the menu opens or closes.
    XCTAssertGreaterThan(moved["Layers", default: 0], 30, "the drag was followed")
    XCTAssertLessThanOrEqual(moved["Conversation", default: 0], 6, "twice per open and close, not every frame")
    XCTAssertLessThanOrEqual(moved["Transcript", default: 0], 6)
    XCTAssertLessThanOrEqual(moved["Composer", default: 0], 6)
    XCTAssertLessThanOrEqual(moved["Menu", default: 0], 6)
    XCTAssertEqual(moved["Message", default: 0], 0, "no message redraws")
  }

  @MainActor
  func testTypingRedrawsOnlyTheMessageBox() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2"])
    let composer = app.textFields["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    let before = counts(app)
    composer.typeText("hello from the phone")
    let typed = delta(before, counts(app))
    print("RENDERS type 20 characters:", typed.sorted { $0.key < $1.key })
    XCTAssertLessThanOrEqual(typed["Composer", default: 0], 25, "about once a key")
    XCTAssertEqual(typed["Conversation", default: 0], 0, "the words are only the box's")
    XCTAssertEqual(typed["Transcript", default: 0], 0)
    XCTAssertEqual(typed["Message", default: 0], 0)
  }

  @MainActor
  func testAStreamingReplyRedrawsOnlyItself() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2", "AXO_PHONE_PREVIEW_LIVE": "stream"])
    XCTAssertTrue(app.staticTexts["Fix the sidebar spacing"].waitForExistence(timeout: 5))
    let before = counts(app)
    app.buttons["play-stream"].tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'word20'")).firstMatch.waitForExistence(timeout: 15))
    let streamed = delta(before, counts(app))
    print("RENDERS stream 20 updates:", streamed.sorted { $0.key < $1.key })
    // The growing reply redraws once an update; the messages above it do not.
    XCTAssertLessThanOrEqual(streamed["Message", default: 0], 30)
    XCTAssertLessThanOrEqual(streamed["Markdown", default: 0], 25)
    XCTAssertLessThanOrEqual(streamed["Conversation", default: 0], 6, "only as Pi starts and stops")
  }

  @MainActor
  func testAReplyInAnotherChatRedrawsNothingHere() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2", "AXO_PHONE_PREVIEW_LIVE": "stream"])
    XCTAssertTrue(app.staticTexts["Fix the sidebar spacing"].waitForExistence(timeout: 5))
    // The other chat already has a conversation on the phone, as a chat that has been working does.
    app.buttons["play-stream-elsewhere"].tap()
    sleep(6)  // 20 updates, five a second
    let before = counts(app)
    app.buttons["play-stream-elsewhere"].tap()
    sleep(6)
    let elsewhere = delta(before, counts(app))
    print("RENDERS stream elsewhere 20 updates:", elsewhere.sorted { $0.key < $1.key })
    XCTAssertEqual(elsewhere["Transcript", default: 0], 0, "another chat's reply is not this chat's news")
    XCTAssertEqual(elsewhere["Conversation", default: 0], 0)
    XCTAssertEqual(elsewhere["Message", default: 0], 0)
  }
}
