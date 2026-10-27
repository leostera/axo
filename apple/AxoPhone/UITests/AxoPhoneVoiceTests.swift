import XCTest

/// Saying a message instead of typing it, against the simulator preview's stand-in recogniser
/// (no microphone, no model download): it "hears" "Make the tests pass" a word at a time.
final class AxoPhoneVoiceTests: XCTestCase {
  private let said = "Make the tests pass"

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(chat: Int) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "\(chat)"]
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    XCTAssertTrue(app.textFields["composer"].waitForExistence(timeout: 15))
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }

  /// Taps the microphone and waits until everything has been heard.
  @MainActor
  private func sayIt(_ app: XCUIApplication) {
    let talk = app.buttons["voice-start"]
    XCTAssertTrue(talk.waitForExistence(timeout: 5))
    talk.tap()
    XCTAssertTrue(element(app, "voice-listening").waitForExistence(timeout: 5), "the box became the listening bar")
    let heard = element(app, "voice-heard")
    XCTAssertTrue(waitUntil(5) { heard.label == said }, "words show as they are heard: \(heard.label)")
  }

  @MainActor
  func testStopPutsWhatWasSaidInTheBoxToReadFirst() {
    let app = launch(chat: 1)
    sayIt(app)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "voice-listening"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["voice-stop"].tap()
    let composer = app.textFields["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntil(5) { composer.value as? String == said })
    XCTAssertTrue(app.buttons["send-message"].isEnabled, "nothing was sent; it waits to be read")
  }

  @MainActor
  func testTheMicrophoneMakesWayForSendOnceSomethingIsTyped() {
    let app = launch(chat: 1)
    XCTAssertTrue(app.buttons["voice-start"].exists)
    XCTAssertFalse(app.buttons["send-message"].exists)
    let composer = app.textFields["composer"]
    composer.tap()
    composer.typeText("Please")
    XCTAssertTrue(app.buttons["send-message"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["voice-start"].exists)
  }

  @MainActor
  func testCancelForgetsWhatWasSaid() {
    let app = launch(chat: 1)
    sayIt(app)
    app.buttons["voice-cancel"].tap()
    XCTAssertTrue(app.buttons["voice-start"].waitForExistence(timeout: 5))
    XCTAssertFalse(element(app, "voice-listening").exists)
    let composer = app.textFields["composer"]
    XCTAssertNotEqual(composer.value as? String, said)
  }

  @MainActor
  func testSendSendsWhatWasSaid() {
    // The preview's second chat refuses messages, so a send shows as "Not sent" with its words
    // back in the box: proof they were sent, and that a refusal does not lose them.
    let app = launch(chat: 2)
    sayIt(app)
    app.buttons["voice-send"].tap()
    let failure = element(app, "chat-failure")
    XCTAssertTrue(failure.waitForExistence(timeout: 10))
    XCTAssertTrue(failure.label.hasPrefix("Not sent"), failure.label)
    XCTAssertEqual(app.textFields["composer"].value as? String, said)
  }
}
