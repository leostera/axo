import XCTest

/// Where things sit on screen, measured, as the person types and moves between layers. Each step
/// records element frames (in points) and a screenshot, so a layout that jumps shows up as
/// numbers, not only as a picture.
final class AxoPhoneLayoutTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = true
  }

  @MainActor
  private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1"].merging(environment) { $1 }
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    XCTAssertTrue(app.staticTexts["conversation-title"].waitForExistence(timeout: 15))
    return app
  }

  /// One measured moment: named frames and a screenshot.
  private struct Step {
    let name: String
    let frames: [String: CGRect]
  }

  private var steps: [Step] = []

  @MainActor
  private func measure(_ app: XCUIApplication, _ name: String, _ elements: [String: XCUIElement]) {
    // Let springs and keyboard animations finish before measuring.
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    var frames: [String: CGRect] = [:]
    for (key, element) in elements where element.exists { frames[key] = element.frame }
    steps.append(Step(name: name, frames: frames))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "layout-\(name)"
    shot.lifetime = .keepAlways
    add(shot)
    let line = frames.keys.sorted().map { key in
      let f = frames[key]!
      return "\(key)=(x \(Int(f.minX)), y \(Int(f.minY)), w \(Int(f.width)), h \(Int(f.height)))"
    }.joined(separator: " ")
    print("LAYOUT \(name): \(line)")
  }

  override func tearDown() {
    let report = steps.map { step in
      "\(step.name): " + step.frames.keys.sorted().map { "\($0)=\(step.frames[$0]!)" }.joined(separator: " ")
    }.joined(separator: "\n")
    let attachment = XCTAttachment(string: report)
    attachment.name = "layout-report"
    attachment.lifetime = .keepAlways
    add(attachment)
    steps = []
    super.tearDown()
  }

  private func frame(_ step: String, _ key: String, file: StaticString = #filePath, line: UInt = #line) -> CGRect {
    guard let frame = steps.first(where: { $0.name == step })?.frames[key] else {
      XCTFail("\(key) was not on screen at \(step)", file: file, line: line)
      return .zero
    }
    return frame
  }

  // MARK: - Typing

  /// The end of the conversation stays just above the composer when the keyboard opens and as
  /// the message grows; the text field keeps its width, so its text never re-wraps when the
  /// expand button appears.
  @MainActor
  func testLayoutWhileTypingSeveralLines() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1"])
    let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "swipe from the left edge")).firstMatch
    XCTAssertTrue(message.waitForExistence(timeout: 10))
    let composer = app.textFields["composer"]
    let elements = [
      "message": message, "composer": composer, "title": app.staticTexts["conversation-title"],
      "expand": app.buttons["Expand message editor"], "jump": app.buttons["Jump to latest"],
    ]
    measure(app, "0-rest", elements)
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    measure(app, "1-keyboard", elements)
    let words = ["Checking", "how", "the", "conversation", "moves", "while", "this", "message", "grows", "line",
                 "by", "line", "until", "it", "is", "long", "enough", "for", "the", "expand", "button", "and",
                 "then", "keeps", "going", "past", "four", "lines", "of", "text", "in", "the", "box", "here"]
    var typed = 0
    var typing: [String] = []
    for (step, count) in [4, 9, 14, 20, 27, 34].enumerated() {
      composer.typeText(words[typed..<count].map { $0 + " " }.joined())
      typed = count
      let name = "\(step + 2)-typed-\(count)-words"
      typing.append(name)
      measure(app, name, elements)
    }

    let open = frame("1-keyboard", "composer")
    let gap = open.minY - frame("1-keyboard", "message").maxY
    XCTAssertGreaterThan(gap, 0, "the last message is above the composer, not under the keyboard")
    for name in typing {
      let composer = frame(name, "composer")
      XCTAssertEqual(composer.width, open.width, accuracy: 0.5, "\(name): the text field keeps its width")
      XCTAssertEqual(composer.minY - frame(name, "message").maxY, gap, accuracy: 2,
        "\(name): the conversation moves with the composer, no more and no less")
    }
    XCTAssertGreaterThan(frame(typing.last!, "composer").height, open.height * 3, "the box grew as the message did")
    // It is drawn above Send, outside Send's own frame: it must still take the tap.
    app.buttons["Expand message editor"].tap()
    XCTAssertTrue(app.textViews["Expanded message"].waitForExistence(timeout: 5), "a long message opens full screen")
  }

  // MARK: - Layers

  /// Opening the chats and coming back, by the strip or by swiping, leaves the conversation
  /// exactly where it was.
  @MainActor
  func testLayoutAfterOpeningAndClosingTheMenu() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1"])
    let elements = [
      "title": app.staticTexts["conversation-title"], "composer": app.textFields["composer"],
      "menuButton": app.buttons["Chats menu"],
    ]
    measure(app, "0-rest", elements)
    app.buttons["Chats menu"].tap()
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 5))
    measure(app, "1-menu-open", elements)
    app.buttons["Back to conversation"].tap()
    measure(app, "2-closed-by-strip", elements)
    // Open by swiping right from the left edge, close by swiping left.
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
    measure(app, "3-menu-open-by-swipe", elements)
    let back = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
    back.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
    measure(app, "4-closed-by-swipe", elements)

    for key in elements.keys {
      let rest = frame("0-rest", key)
      for step in ["2-closed-by-strip", "4-closed-by-swipe"] {
        XCTAssertEqual(frame(step, key), rest, "\(step): \(key) is back where it was")
      }
      XCTAssertGreaterThan(frame("1-menu-open", key).minX, rest.minX + 200, "the menu pushes the conversation aside")
    }
  }
}
