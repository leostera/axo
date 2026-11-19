import UIKit
import XCTest

/// The chat's Pi, from the phone (RFD0033): the model in the box and picking another, the `/`
/// list of its commands, holding Send for Follow-up or Steer, and Restart in the chat's info. The
/// preview's first chat is working, so it takes prompts queued, as a busy Pi does; every chat
/// lists commands and models and restarts.
final class AxoMobileSessionControlsTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(chat: Int, appearance: String = "light") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "\(chat)"]
    app.launchArguments = ["-appearance", appearance]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    _ = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "New chat"), object: title)], timeout: 10)
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

  @MainActor
  private func capture(_ app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    Snapshots.save(app.screenshot().pngRepresentation, named: name)
  }

  @MainActor
  private func type(_ text: String, in app: XCUIApplication) -> XCUIElement {
    let composer = app.textViews["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText(text)
    return composer
  }

  @MainActor
  func testComposerSelectorsShareOneRowAndDoNotSendTheDraft() {
    let app = launch(chat: 2)
    let composer = type("Keep this unsent", in: app)
    let selectors = ["host-picker", "agent-picker", "model-picker", "thinking-picker"].map { element(app, $0) }
    for item in selectors {
      XCTAssertTrue(item.waitForExistence(timeout: 5))
      XCTAssertTrue(item.isHittable)
    }
    for index in 1..<selectors.count {
      XCTAssertGreaterThanOrEqual(selectors[index].frame.minX, selectors[index - 1].frame.maxX - 1)
      XCTAssertEqual(selectors[index].frame.midY, selectors[0].frame.midY, accuracy: 2)
    }
    selectors[3].tap()
    XCTAssertTrue(element(app, "thinking-medium").waitForExistence(timeout: 5))
    element(app, "thinking-medium").tap()
    XCTAssertEqual(composer.value as? String, "Keep this unsent")
    capture(app, named: "composer-four-selectors")
  }

  // MARK: - The model

  @MainActor
  func testTheBoxNamesTheModelAndPickingAnotherOrALevelChangesIt() {
    let app = launch(chat: 2)
    app.textViews["composer"].tapWhereItIs()
    let model = element(app, "model-picker")
    XCTAssertTrue(model.waitForExistence(timeout: 5))
    XCTAssertEqual(model.label, "Model: Opus 4.1")
    let thinking = element(app, "thinking-picker")
    XCTAssertEqual(thinking.label, "Thinking: High")
    model.tap()
    let gpt = element(app, "model-gpt-5")
    XCTAssertTrue(gpt.waitForExistence(timeout: 5), "the models are read as the menu opens")
    XCTAssertTrue(app.staticTexts["Anthropic"].exists && app.staticTexts["OpenAI"].exists, "grouped by provider")
    XCTAssertTrue(element(app, "model-claude-opus-4-1").isSelected, "the one Pi runs is checked")
    XCTAssertFalse(element(app, "thinking-xhigh").exists, "thinking has its own independent picker")
    capture(app, named: "model-menu-light")
    gpt.tap()
    XCTAssertTrue(waitUntil(5) { model.label == "Model: GPT-5" }, model.label)

    thinking.tap()
    let medium = element(app, "thinking-medium")
    XCTAssertTrue(medium.waitForExistence(timeout: 5))
    XCTAssertFalse(element(app, "thinking-xhigh").exists, "GPT-5 has no Extra High")
    medium.tap()
    XCTAssertTrue(waitUntil(5) { thinking.label == "Thinking: Medium" }, thinking.label)
    XCTAssertEqual(model.label, "Model: GPT-5")
  }

  // MARK: - Slash commands

  @MainActor
  func testASlashListsTheChatsCommandsNarrowsAsTypedAndPutsOneInTheBox() {
    let app = launch(chat: 2)
    let composer = type("/", in: app)
    let list = element(app, "slash-commands")
    XCTAssertTrue(element(app, "slash-review").waitForExistence(timeout: 5), "read from the chat's Pi")
    XCTAssertTrue(app.staticTexts["Share this conversation"].exists, "each with what it does")
    capture(app, named: "slash-commands-light")
    composer.typeText("re")
    XCTAssertTrue(waitUntil(5) { !self.element(app, "slash-hivemind").exists })
    XCTAssertTrue(element(app, "slash-review").exists && element(app, "slash-release").exists)
    element(app, "slash-review").tap()
    XCTAssertEqual(composer.value as? String, "/review ", "ready for arguments")
    XCTAssertTrue(waitUntil(5) { !list.exists }, "the list goes once arguments start")
  }

  // MARK: - Interrupt, steer or follow up

  private func rows(_ app: XCUIApplication, _ identifier: String, saying words: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, words))
  }

  @MainActor
  func testATapOnSendInterruptsTheWorkingAgent() {
    let app = launch(chat: 1)
    _ = type("Stop and look at main", in: app)
    app.buttons["send-message"].tap()
    let interrupting = rows(app, "queuedPrompt", saying: "Interrupting").firstMatch
    XCTAssertTrue(interrupting.waitForExistence(timeout: 10), "the log holds it as an interrupt")
    XCTAssertTrue(interrupting.label.contains("Stop and look at main"), interrupting.label)
    XCTAssertFalse(element(app, "send-steer").exists, "a tap offers nothing")
  }

  @MainActor
  func testHoldingSendSendsNothingAndOffersSteerOrFollowUp() {
    let app = launch(chat: 1)
    let composer = type("Look at main instead", in: app)
    let send = app.buttons["send-message"]
    XCTAssertTrue(send.isEnabled)
    send.press(forDuration: 1.0)
    let steer = element(app, "send-steer")
    XCTAssertTrue(steer.waitForExistence(timeout: 5), "holding Send offers Steer")
    XCTAssertTrue(element(app, "send-followUp").exists, "and Follow up")
    XCTAssertTrue(app.staticTexts["At the agent's next step"].exists && app.staticTexts["After the current reply"].exists)
    // Held and let go: nothing has gone yet.
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "queuedPrompt").count, 0, "nothing sent by the hold")
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "pendingPrompt").count, 0)
    XCTAssertEqual(composer.value as? String, "Look at main instead")
    capture(app, named: "send-menu-light")
    steer.tap()
    let steering = rows(app, "queuedPrompt", saying: "Steering").firstMatch
    XCTAssertTrue(steering.waitForExistence(timeout: 10), "sent once chosen, as a steer")
    XCTAssertTrue(steering.label.contains("Look at main instead"), steering.label)

    _ = type("Then update the docs", in: app)
    send.press(forDuration: 1.0)
    let followUp = element(app, "send-followUp")
    XCTAssertTrue(followUp.waitForExistence(timeout: 5))
    followUp.tap()
    let queued = rows(app, "queuedPrompt", saying: "Queued").firstMatch
    XCTAssertTrue(queued.waitForExistence(timeout: 10))
    XCTAssertTrue(queued.label.contains("Then update the docs"), queued.label)
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "queuedPrompt").count, 2, "each once")
    app.tap()
    capture(app, named: "queued-light")
  }

  // MARK: - The box's look (compared against apple/AxoMobile/Snapshots/Phone)

  @MainActor
  func testComposerControlLayoutInBothAppearances() {
    for appearance in ["light", "dark"] {
      let app = launch(chat: 2, appearance: appearance)
      let composer = type("Check the Send button", in: app)
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
      let selectors = ["host-picker", "agent-picker", "model-picker", "thinking-picker"].map { element(app, $0) }
      for selector in selectors { XCTAssertTrue(selector.isHittable) }
      XCTAssertEqual(composer.value as? String, "Check the Send button")
      let suffix = UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : ""
      capture(app, named: "composer-text-\(appearance)\(suffix)")
    }
  }

  @MainActor
  func testVisualSnapshotComposerWithTextLight() {
    let app = launch(chat: 2, appearance: "light")
    _ = type("Check the Send button", in: app)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    Snapshots.check(app, named: UIDevice.current.userInterfaceIdiom == .pad ? "composer-text-light-ipad" : "composer-text-light", in: self)
  }

  @MainActor
  func testVisualSnapshotComposerWithTextDark() {
    let app = launch(chat: 2, appearance: "dark")
    _ = type("Check the Send button", in: app)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    Snapshots.check(app, named: UIDevice.current.userInterfaceIdiom == .pad ? "composer-text-dark-ipad" : "composer-text-dark", in: self)
  }

  // MARK: - Restart

  @MainActor
  func testRestartAsksFirstAndSaysRestartingUntilPiIsReady() {
    let app = launch(chat: 2)
    let restart = element(app, "restart-pi")
    if UIDevice.current.userInterfaceIdiom == .pad {
      app.buttons["Chat info"].tapWhereItIs()
    } else {
      // Phone layers need an intentional full swipe; a short flick can settle back.
      let readiness = app.descendants(matching: .any).matching(identifier: "layer-readiness").firstMatch
      for _ in 0..<3 where readiness.value as? String != "3:ready" {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).press(
          forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45)),
          withVelocity: XCUIGestureVelocity(1200), thenHoldForDuration: 0)
      }
      XCTAssertTrue(waitUntil(8) { readiness.value as? String == "3:ready" }, "the info layer is actually visible")
    }
    XCTAssertTrue(restart.waitForExistence(timeout: 5))
    let panel = app.scrollViews.containing(.button, identifier: "restart-pi").firstMatch
    for _ in 0..<4 where !restart.isHittable {
      if panel.exists { panel.swipeUp() } else { app.swipeUp() }
    }
    XCTAssertEqual(restart.label, "Restart Pi")
    restart.tap()
    XCTAssertTrue(app.staticTexts["A reply it is writing stops. The conversation is kept."].waitForExistence(timeout: 5), "it asks first")
    app.buttons.matching(NSPredicate(format: "label == 'Restart Pi'")).allElementsBoundByIndex
      .first { $0.identifier != "restart-pi" }?.tap()
    XCTAssertTrue(waitUntil(5) { restart.label == "Restarting…" }, restart.label)
    XCTAssertTrue(waitUntil(15) { restart.label == "Restart Pi" }, "done once Pi is ready again: \(restart.label)")
  }
}
