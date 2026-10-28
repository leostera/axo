import XCTest

/// The screens are layers: the conversation on top of the chats on top of the account. A swipe
/// right anywhere pushes the layer showing aside to show the one beneath; a swipe left brings it
/// back. Only the layer showing can be used; the strip of the one beside it brings that one back.
final class AxoPhoneLayerTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1"].merging(environment) { $1 }
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    // A preview opens its chat a moment after launch; a tap before that is lost.
    var label = title.label
    for _ in 0..<20 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
      if title.label == label { break }
      label = title.label
    }
    return app
  }

  fileprivate enum Showing { case conversation, chats, account, info }

  /// Which layer is showing, told by where the layers lie. (The accessibility tree keeps every
  /// layer for UI tests, hidden or not, so what exists says nothing; where it is does.)
  @MainActor
  private func waitFor(
    _ layer: Showing, in app: XCUIApplication, timeout: TimeInterval = 5,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if LayerPositions(app).showing == layer { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    let where_ = ["Chats menu", "New chat"].map { name in
      let button = app.buttons[name]
      return "\(name): \(button.exists ? "\(button.frame)" : "missing")"
    }
    XCTFail("wanted \(layer), saw \(String(describing: LayerPositions(app).showing)); \(where_)", file: file, line: line)
    return false
  }

  /// A quick flick from the middle of the screen, not the edge.
  @MainActor
  private func flick(_ app: XCUIApplication, right: Bool) {
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.35 : 0.65, dy: 0.45))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.6 : 0.4, dy: 0.45))
    // Too short a way to settle there by distance; its momentum carries it on
    // (`LayerStackGeometry.projected`).
    start.press(forDuration: 0.01, thenDragTo: end, withVelocity: XCUIGestureVelocity(2400), thenHoldForDuration: 0)
  }

  @MainActor
  func testTwoFlicksRightGoAllTheWayDownAndTwoLeftComeBack() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2"])
    XCTAssertTrue(waitFor(.conversation, in: app))
    flick(app, right: true)
    XCTAssertTrue(waitFor(.chats, in: app), "one flick, one layer: the chats")
    flick(app, right: true)
    XCTAssertTrue(waitFor(.account, in: app), "another: the account")
    flick(app, right: true)
    XCTAssertTrue(waitFor(.account, in: app), "nothing below the account")
    flick(app, right: false)
    XCTAssertTrue(waitFor(.chats, in: app))
    flick(app, right: false)
    XCTAssertTrue(waitFor(.conversation, in: app))
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "Fix the sidebar spacing", "the same chat, still open")
  }

  @MainActor
  func testASwipeLeftPullsInTheChatInfoAndARightOneSendsItBack() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2"])
    flick(app, right: false)
    XCTAssertTrue(waitFor(.info, in: app), "the info comes in over the conversation")
    XCTAssertTrue(app.staticTexts["session-info-title"].label.hasSuffix("Fix the sidebar spacing"), "about the open chat")
    flick(app, right: false)
    XCTAssertTrue(waitFor(.info, in: app), "nothing above the info")
    flick(app, right: true)
    XCTAssertTrue(waitFor(.conversation, in: app))
    flick(app, right: false)
    XCTAssertTrue(waitFor(.info, in: app))
    app.buttons["Back to conversation"].tapWhereItIs()
    XCTAssertTrue(waitFor(.conversation, in: app), "the conversation's strip brings it back")
  }

  @MainActor
  func testASwipeThatStartsOnAChatDoesNotOpenIt() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2"])
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(waitFor(.chats, in: app))
    let row = app.buttons["Explain the relay"]
    // A slow drag along the row that lets go where it started settles back, opening nothing.
    let middle = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: -60, dy: 0)),
      withVelocity: .slow, thenHoldForDuration: 0)
    XCTAssertTrue(waitFor(.chats, in: app))
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "Fix the sidebar spacing", "the drag opened no chat")
    // A flick along the row goes back to the conversation, the same chat still open.
    middle.press(forDuration: 0.01, thenDragTo: middle.withOffset(CGVector(dx: -110, dy: 0)),
      withVelocity: XCUIGestureVelocity(2400), thenHoldForDuration: 0)
    XCTAssertTrue(waitFor(.conversation, in: app))
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "Fix the sidebar spacing", "the swipe opened no chat")
  }

  @MainActor
  func testPairingAMacFromTheAccountShowsACodeToEnterOnTheMac() {
    let app = launch(["AXO_PHONE_PREVIEW_HOSTS": "1"])
    XCTAssertTrue(waitFor(.account, in: app))
    app.buttons["Pair a Mac"].tapWhereItIs()
    let code = app.staticTexts["pairing-code"]
    XCTAssertTrue(code.waitForExistence(timeout: 5))
    XCTAssertEqual(code.label, "7 K Q 2 - M 4 X D", "read out one character at a time")
    XCTAssertTrue(app.staticTexts["Waiting for your Mac…"].exists)
    XCTAssertTrue(app.buttons["Send to Mac"].exists)
    app.buttons["Cancel"].tap()
    XCTAssertFalse(code.waitForExistence(timeout: 2) && code.isHittable)
  }

  @MainActor
  func testAShortSlowDragSettlesBackWhereItWas() {
    let app = launch()
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
    start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)),
      withVelocity: .slow, thenHoldForDuration: 0.3)
    XCTAssertTrue(waitFor(.conversation, in: app), "not far enough, too slow: back")
  }

  @MainActor
  func testTheStripOfTheLayerAboveBringsItBack() {
    let app = launch(["AXO_PHONE_PREVIEW_HOSTS": "1"])
    XCTAssertTrue(waitFor(.account, in: app))
    app.buttons["Back to chats"].tapWhereItIs()
    XCTAssertTrue(waitFor(.chats, in: app))
    app.buttons["Back to conversation"].tapWhereItIs()
    XCTAssertTrue(waitFor(.conversation, in: app))
  }

  @MainActor
  func testPushingTheConversationAsidePutsTheKeyboardAway() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2"])
    let composer = app.textFields["composer"]
    composer.tapWhereItIs()
    XCTAssertTrue(hasFocus(composer, true))
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(waitFor(.chats, in: app))
    XCTAssertTrue(hasFocus(composer, false), "the keyboard went with the conversation")
  }

  /// Whether `element` has the keyboard's focus (the simulator may show no keyboard at all).
  @MainActor
  private func hasFocus(_ element: XCUIElement, _ focused: Bool) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if (element.value(forKey: "hasKeyboardFocus") as? Bool ?? false) == focused { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }
}

/// Where each layer lies, from an element only it has at its left edge, and so which one shows.
@MainActor
private struct LayerPositions {
  let showing: AxoPhoneLayerTests.Showing?

  init(_ app: XCUIApplication) {
    let width = app.windows.firstMatch.frame.width
    func left(_ element: XCUIElement) -> CGFloat? { element.exists ? element.frame.minX : nil }
    // The menu button sits at the conversation's left, the Chat button at the chats' left.
    let conversation = left(app.buttons["Chats menu"])
    let chats = left(app.buttons["New chat"])
    let atRest: (CGFloat?) -> Bool = { ($0 ?? -1) >= 0 && ($0 ?? .infinity) < 60 }
    // The info's title is centred in its layer: in the middle of the screen once it is in.
    let info = app.staticTexts["session-info-title"]
    let infoIn = info.exists && abs(info.frame.midX - (width - min(width * 0.79, 360) / 2)) < 2
    if infoIn {
      showing = .info
    } else if atRest(conversation) {
      showing = .conversation
    } else if atRest(chats), let conversation, conversation > width * 0.7 {
      showing = .chats
    } else if let chats, chats > width * 0.7, conversation.map({ $0 >= width }) ?? true {
      showing = .account
    } else {
      showing = nil
    }
  }
}
