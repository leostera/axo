import XCTest

/// The chat's Pi, from the phone (RFD0033): the model in the box and picking another, the `/`
/// list of its commands, holding Send for Follow-up or Steer, and Restart in the chat's info. The
/// preview's first chat is working, so it takes prompts queued, as a busy Pi does; every chat
/// lists commands and models and restarts.
final class AxoPhoneSessionControlsTests: XCTestCase {
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
    let composer = app.textFields["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText(text)
    return composer
  }

  // MARK: - The model

  @MainActor
  func testTheBoxNamesTheModelAndPickingAnotherOrALevelChangesIt() {
    let app = launch(chat: 2)
    let model = element(app, "model-picker")
    XCTAssertTrue(model.waitForExistence(timeout: 5))
    XCTAssertEqual(model.label, "Model: Opus 4.1 · High")
    model.tap()
    let gpt = element(app, "model-gpt-5")
    XCTAssertTrue(gpt.waitForExistence(timeout: 5), "the models are read as the menu opens")
    XCTAssertTrue(app.staticTexts["Anthropic"].exists && app.staticTexts["OpenAI"].exists, "grouped by provider")
    XCTAssertTrue(element(app, "model-claude-opus-4-1").isSelected, "the one Pi runs is checked")
    XCTAssertTrue(element(app, "thinking-xhigh").exists, "then the levels the current model supports")
    capture(app, named: "model-menu-light")
    gpt.tap()
    XCTAssertTrue(waitUntil(5) { model.label == "Model: GPT-5 · High" }, model.label)

    model.tap()
    let medium = element(app, "thinking-medium")
    XCTAssertTrue(medium.waitForExistence(timeout: 5))
    XCTAssertFalse(element(app, "thinking-xhigh").exists, "GPT-5 has no Extra High")
    medium.tap()
    XCTAssertTrue(waitUntil(5) { model.label == "Model: GPT-5 · Medium" }, model.label)
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

  // MARK: - The box's look (compared against apple/AxoPhone/Snapshots/Phone)

  @MainActor
  func testVisualSnapshotComposerWithTextLight() {
    let app = launch(chat: 2, appearance: "light")
    _ = type("Check the Send button", in: app)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    Snapshots.check(app, named: "composer-text-light", in: self)
  }

  @MainActor
  func testVisualSnapshotComposerWithTextDark() {
    let app = launch(chat: 2, appearance: "dark")
    _ = type("Check the Send button", in: app)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    Snapshots.check(app, named: "composer-text-dark", in: self)
  }

  // MARK: - Restart

  @MainActor
  func testRestartAsksFirstAndSaysRestartingUntilPiIsReady() {
    let app = launch(chat: 2)
    // A flick left pulls in the chat's info; one the stack takes for a tap is flicked again.
    let restart = element(app, "restart-pi")
    for _ in 0..<3 where !restart.waitForExistence(timeout: 3) {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
      start.press(
        forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)),
        withVelocity: XCUIGestureVelocity(2400), thenHoldForDuration: 0)
    }
    XCTAssertTrue(restart.waitForExistence(timeout: 5))
    for _ in 0..<4 where !restart.isHittable { app.swipeUp() }
    XCTAssertEqual(restart.label, "Restart Pi")
    restart.tap()
    XCTAssertTrue(app.staticTexts["A reply it is writing stops. The conversation is kept."].waitForExistence(timeout: 5), "it asks first")
    app.buttons.matching(NSPredicate(format: "label == 'Restart Pi'")).allElementsBoundByIndex
      .first { $0.identifier != "restart-pi" }?.tap()
    XCTAssertTrue(waitUntil(5) { restart.label == "Restarting…" }, restart.label)
    XCTAssertTrue(waitUntil(15) { restart.label == "Restart Pi" }, "done once Pi is ready again: \(restart.label)")
  }
}
