import XCTest

/// The phone app driven as a person would, against its simulator preview (sample Macs and chats,
/// a relay that answers just enough). Nothing here signs in or reaches a real Mac.
final class AxoPhoneUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1"].merging(environment) { $1 }
    app.launch()
    XCTAssertTrue(app.staticTexts["conversation-title"].waitForExistence(timeout: 15))
    return app
  }

  /// Waits for the sliding menu to be gone (it takes a moment to slide away). Its panels are
  /// not left behind under the conversation.
  private func menuClosed(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !app.buttons["New chat"].exists, !app.buttons["Back to chats"].exists, app.buttons["Chats menu"].exists {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  @MainActor
  private func swipe(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  // MARK: - Navigation

  @MainActor
  func testItOpensOnABlankNewChat() {
    let app = launch()
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat")
    XCTAssertTrue(app.staticTexts["What are we working on?"].exists)
    XCTAssertTrue(app.textFields["composer"].exists)
  }

  @MainActor
  func testAnEdgeSwipeOpensTheChatsAndASecondSwipeTheAccount() {
    let app = launch()
    swipe(app, from: 0.01, to: 0.7)
    XCTAssertTrue(app.buttons["Ship the remote Workbench"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["New chat"].isHittable)

    swipe(app, from: 0.2, to: 0.75)
    XCTAssertTrue(element(app, "hosts-panel").waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Leandro"].exists, "the account is shown")
    XCTAssertTrue(app.buttons["Studio"].exists, "and its Macs")
    XCTAssertTrue(app.buttons["Old iMac"].exists)

    swipe(app, from: 0.7, to: 0.1)
    XCTAssertTrue(app.buttons["Ship the remote Workbench"].waitForExistence(timeout: 5), "back to the chats")
    swipe(app, from: 0.7, to: 0.1)
    XCTAssertTrue(menuClosed(app), "and closed")
  }

  @MainActor
  func testTheAccountButtonOpensTheAccountAndTheBackButtonReturns() {
    let app = launch()
    app.buttons["Chats menu"].tap()
    app.buttons["Account and Macs"].tap()
    XCTAssertTrue(element(app, "hosts-panel").waitForExistence(timeout: 5))
    app.buttons["Back to chats"].tap()
    XCTAssertTrue(app.buttons["Ship the remote Workbench"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testTappingTheConversationBesideTheMenuClosesIt() {
    let app = launch()
    app.buttons["Chats menu"].tap()
    XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 5))
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertTrue(menuClosed(app))
  }

  @MainActor
  func testAnOfflineMacCannotStartAChatAndAnOnlineOneDoes() {
    let app = launch(["AXO_PHONE_PREVIEW_HOSTS": "1"])
    XCTAssertTrue(element(app, "hosts-panel").waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Old iMac"].isEnabled)
    app.buttons["Studio"].tap()
    XCTAssertTrue(menuClosed(app))
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat")
  }

  @MainActor
  func testTheMenuGroupsChatsByWorkspaceShowsEmptyOnesAndWhoIsWorking() {
    let app = launch()
    app.buttons["Chats menu"].tap()
    XCTAssertTrue(app.staticTexts["Axo · Studio"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Home · Old iMac"].exists)
    XCTAssertTrue(app.staticTexts["Website · Studio"].waitForExistence(timeout: 5), "a Workspace with no chats is listed")
    XCTAssertTrue(app.staticTexts["No chats yet"].exists)
    XCTAssertEqual(app.buttons["Ship the remote Workbench"].value as? String, "Working")
  }

  @MainActor
  func testChoosingAChatOpensItAndTheNewChatButtonLeavesIt() {
    let app = launch()
    app.buttons["Chats menu"].tap()
    app.buttons["Fix the sidebar spacing"].tap()
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "Fix the sidebar spacing")
    XCTAssertTrue(app.staticTexts["I'll start with the menu."].waitForExistence(timeout: 5))
    app.buttons["Chats menu"].tap()
    app.buttons["New chat"].tap()
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat")
  }

  @MainActor
  func testSearchFindsAChatByName() {
    let app = launch()
    app.buttons["Chats menu"].tap()
    app.buttons["Search chats"].tap()
    let field = app.textFields["search-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("relay")
    let result = app.buttons.matching(identifier: "search-result").firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    result.tap()
    XCTAssertTrue(app.staticTexts["Explain the relay"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "Explain the relay")
  }

  @MainActor
  func testSettingsOpenFromTheMenu() {
    let app = launch()
    app.buttons["Chats menu"].tap()
    app.buttons["Settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Sign out"].exists)
  }

  // MARK: - Conversation

  @MainActor
  func testAReplyBeingWrittenAndARunningToolShowAsTheyGrow() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1", "AXO_PHONE_PREVIEW_LIVE": "reply"])
    XCTAssertTrue(app.staticTexts["Using tools…"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Still waiting on the")).firstMatch.exists)
    XCTAssertTrue(app.staticTexts["Latest output"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "PhoneWorkbenchTests running")).firstMatch.exists)
  }

  @MainActor
  func testStoppingAReplyAsksFirstThenSaysItIsStopping() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1", "AXO_PHONE_PREVIEW_LIVE": "reply"])
    let stop = app.buttons["Stop the reply"]
    XCTAssertTrue(stop.waitForExistence(timeout: 10))
    stop.tap()
    let alert = app.alerts["Stop the reply?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    alert.buttons["Keep going"].tap()
    XCTAssertTrue(app.staticTexts["Using tools…"].exists, "keeping going changes nothing")
    stop.tap()
    app.alerts["Stop the reply?"].buttons["Stop"].tap()
    XCTAssertTrue(app.staticTexts["Stopping…"].waitForExistence(timeout: 5))
    XCTAssertFalse(stop.isEnabled, "one stop at a time")
  }

  @MainActor
  func testAQuestionCanBeAnsweredFromThePhone() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1", "AXO_PHONE_PREVIEW_LIVE": "question"])
    XCTAssertTrue(element(app, "questionCard").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Delete the build folder first?"].exists)
    XCTAssertTrue(app.staticTexts["Waiting for your answer"].exists)
    XCTAssertTrue(app.buttons["Yes"].isEnabled)
    app.buttons["Yes"].tap()
    XCTAssertFalse(element(app, "chat-failure").waitForExistence(timeout: 2), "the Mac took the answer")
  }

  @MainActor
  func testAMessageTheMacRefusesSaysNotSentAndKeepsTheWords() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "2"])
    let composer = app.textFields["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Ship it")
    app.buttons["send-message"].tap()
    let failure = element(app, "chat-failure")
    XCTAssertTrue(failure.waitForExistence(timeout: 10))
    XCTAssertTrue(failure.label.hasPrefix("Not sent"), failure.label)
    XCTAssertEqual(composer.value as? String, "Ship it", "the words are back in the box")
  }

  @MainActor
  func testScrollingUpOffersAWayBackToTheEnd() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1"])
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "swipe from the left edge")).firstMatch.waitForExistence(timeout: 10))
    for _ in 0..<3 { app.swipeDown() }
    let jump = app.buttons["Jump to latest"]
    XCTAssertTrue(jump.waitForExistence(timeout: 5))
    jump.tap()
    XCTAssertFalse(jump.waitForExistence(timeout: 2) && jump.isHittable, "at the end the button goes away")
  }
}
