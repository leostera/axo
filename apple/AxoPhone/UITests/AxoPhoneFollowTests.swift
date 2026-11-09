import ImageIO
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

  /// The left edge of what the transcript draws, in points: the leftmost dark pixel between the
  /// header and the composer. What is drawn, not what accessibility reports: a row being resized
  /// reports a frame laid out for its next size for a moment, while it is drawn where it was.
  @MainActor
  private func columnEdges(_ app: XCUIApplication) -> Set<Int> {
    guard
      let source = CGImageSourceCreateWithData(app.screenshot().pngRepresentation as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return [] }
    let scale = Double(image.width) / Double(app.frame.width)
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let top = Int(120 * scale), bottom = Int((app.textFields["composer"].frame.minY - 60) * scale)
    var left = Int.max
    for y in stride(from: top, to: bottom, by: 2) {
      for x in 0..<min(width, Int(60 * scale)) {
        let i = (y * width + x) * 4
        if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 3 * 128 {
          left = min(left, x)
          break
        }
      }
    }
    return left == .max ? [] : [Int((Double(left) / scale).rounded())]
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
    XCTAssertTrue(waitUntil(30) { inView(reply(app, 30), app) }, "the last reply is in view")
    edges.formUnion(columnEdges(app))
    XCTAssertEqual(edges.count, 1, "the transcript stays in its column: \(edges.sorted())")
    XCTAssertFalse(app.buttons["Jump to new message"].exists, "following, nothing is waiting below")
  }

  /// Following rests where the scroll view itself would: at the last row, not past it. A move to
  /// the end used to land a bar's height beyond it, and a row measured shorter than estimated left
  /// it further still, to a screen of nothing; a drag let go there bounced back to the real end.
  @MainActor
  func testFollowingRestsAtTheEndNotPastIt() {
    let app = launch()
    app.buttons["play-flood"].tap()
    XCTAssertTrue(waitUntil(30) { inView(reply(app, 30), app) }, "the last reply is in view")
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    let followed = reply(app, 30).frame.minY
    app.swipeUp(velocity: .slow)
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    let bounced = reply(app, 30).frame.minY
    XCTAssertEqual(followed, bounced, accuracy: 2, "a drag at the end bounces back to where following left it")
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
    // Each reply's words are let out, hurried while more wait behind it.
    let followed = waitUntil(30) { inView(reply(app, 30), app) }
    let trace = app.descendants(matching: .any).matching(identifier: "follow-trace").firstMatch
    print("FOLLOW TRACE:", trace.exists ? trace.label : "none")
    print("REPLY 30:", reply(app, 30).exists ? "\(reply(app, 30).frame)" : "absent", "composer:", app.textFields["composer"].frame)
    XCTAssertTrue(followed, "followed to the last reply")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    XCTAssertTrue(inView(reply(app, 30), app))
    XCTAssertFalse(jump.exists && jump.isHittable, "at the end the button goes away")
  }
}
