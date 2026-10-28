import XCTest

/// A conversation follows what is new: replies landing keep the end in view, a reader who
/// scrolled up is left where they are, and "Jump to new message" brings them back to following.
/// The transcript never moves sideways while it does.
final class AxoPhoneFollowTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "1", "AXO_PHONE_PREVIEW_LIVE": "flood"]
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "swipe from the left edge")).firstMatch
      .waitForExistence(timeout: 15))
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    return app
  }

  private func reply(_ app: XCUIApplication, _ number: Int) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Flood reply \(number):")).firstMatch
  }

  /// Whether `element` is on screen, above the composer.
  @MainActor
  private func inView(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
    guard element.exists else { return false }
    let frame = element.frame
    let composer = app.textFields["composer"].frame
    return frame.maxY > 0 && frame.minY < composer.minY && frame.maxY <= composer.minY + 1
  }

  /// The left edge of whichever flood replies are on screen: the transcript's column.
  @MainActor
  private func columnEdges(_ app: XCUIApplication) -> Set<Int> {
    let replies = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Flood reply '")).allElementsBoundByIndex
    return Set(replies.filter { $0.exists && $0.frame.maxY > 0 }.map { Int($0.frame.minX.rounded()) })
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }

  @MainActor
  func testRepliesLandingKeepTheEndInViewWithoutMovingSideways() {
    let app = launch()
    app.buttons["play-flood"].tap()
    var edges = Set<Int>()
    // Thirty replies at ten a second; look as they land.
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
      edges.formUnion(columnEdges(app))
    }
    XCTAssertTrue(waitUntil(10) { inView(reply(app, 30), app) }, "the last reply is in view")
    edges.formUnion(columnEdges(app))
    XCTAssertEqual(edges.count, 1, "the transcript stays in its column: \(edges.sorted())")
    XCTAssertFalse(app.buttons["Jump to new message"].exists, "following, nothing is waiting below")
  }

  @MainActor
  func testAfterJumpingToTheNewMessageItKeepsFollowing() {
    let app = launch()
    for _ in 0..<3 { app.swipeDown() }
    app.buttons["play-flood"].tap()
    let jump = app.buttons["Jump to new message"]
    XCTAssertTrue(jump.waitForExistence(timeout: 5), "scrolled up, the reader is told something is new")
    XCTAssertFalse(inView(reply(app, 1), app), "and left where they were")
    jump.tap()
    // Replies keep landing after the jump: they stay in view, to the last one.
    let followed = waitUntil(10) { inView(reply(app, 30), app) }
    let trace = app.descendants(matching: .any).matching(identifier: "follow-trace").firstMatch
    print("FOLLOW TRACE:", trace.exists ? trace.label : "none")
    print("REPLY 30:", reply(app, 30).exists ? "\(reply(app, 30).frame)" : "absent", "composer:", app.textFields["composer"].frame)
    XCTAssertTrue(followed, "followed to the last reply")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertTrue(inView(reply(app, 30), app))
    XCTAssertFalse(jump.exists && jump.isHittable, "at the end the button goes away")
  }
}
