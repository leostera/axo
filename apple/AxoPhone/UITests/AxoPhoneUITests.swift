import XCTest

/// The phone app driven as a person would, against its simulator preview (sample Macs and chats,
/// a relay that answers just enough). Nothing here signs in or reaches a real Mac.
final class AxoPhoneUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(
    _ environment: [String: String] = [:], appearance: String = "light", listing: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1"].merging(environment) { $1 }
    // NSArgumentDomain overrides AppStorage without leaving a preference behind in the simulator.
    app.launchArguments = ["-appearance", appearance] + (listing.map { ["-chatListMode", $0] } ?? [])
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    // A preview opens its chat a moment after launch; a tap before that is lost. One asked for
    // is open once the title is no longer the blank chat's.
    if app.launchEnvironment["AXO_PHONE_PREVIEW_CHAT"] != nil {
      let opened = NSPredicate(format: "label != %@", "New chat")
      _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: opened, object: title)], timeout: 10)
    }
    var label = title.label
    for _ in 0..<20 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
      if title.label == label { break }
      label = title.label
    }
    return app
  }

  @MainActor
  private func capture(_ app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    Snapshots.save(app.screenshot().pngRepresentation, named: name)
  }

  // Every layer stays in the accessibility tree UI tests read (VoiceOver reads only the one
  // showing), so these go by where things lie rather than by what exists.

  /// Waits for the conversation to cover the other layers again (it takes a moment to slide back).
  private func menuClosed(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
    let menu = app.buttons["Chats menu"]
    return waitUntil(timeout) { settled(menu) && menu.frame.minX < 60 }
  }

  /// The account layer, ready to use: the chats pushed aside to the right.
  private func accountShowing(_ app: XCUIApplication) -> Bool {
    let chat = app.buttons["New chat"]
    return waitUntil(5) { settled(chat) && chat.frame.minX > app.windows.firstMatch.frame.width * 0.7 }
  }

  /// Waits until `element` is on the screen and has stopped moving, so a tap lands on it.
  private func hittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    waitUntil(timeout) {
      settled(element) && element.frame.minX >= 0
        && element.frame.maxX <= XCUIApplication().windows.firstMatch.frame.width
    }
  }

  /// Whether `element` is where it was a moment ago.
  private func settled(_ element: XCUIElement) -> Bool {
    guard element.exists else { return false }
    let before = element.frame
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    return element.exists && element.frame == before
  }

  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
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
    XCTAssertTrue(hittable(app.buttons["Ship the remote Workbench"]))
    XCTAssertTrue(hittable(app.buttons["New chat"]))

    swipe(app, from: 0.2, to: 0.75)
    XCTAssertTrue(accountShowing(app))
    XCTAssertTrue(app.staticTexts["Leandro"].exists, "the account is shown")
    XCTAssertTrue(app.buttons["Studio"].exists, "and its Macs")
    XCTAssertTrue(app.buttons["Old iMac"].exists)

    swipe(app, from: 0.7, to: 0.1)
    XCTAssertTrue(hittable(app.buttons["Ship the remote Workbench"]), "back to the chats")
    swipe(app, from: 0.7, to: 0.1)
    XCTAssertTrue(menuClosed(app), "and closed")
  }

  @MainActor
  func testTheAccountButtonOpensTheAccountAndTheBackButtonReturns() {
    let app = launch()
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(hittable(app.buttons["Account and Macs"]))
    app.buttons["Account and Macs"].tapWhereItIs()
    XCTAssertTrue(accountShowing(app))
    app.buttons["Back to chats"].tapWhereItIs()
    XCTAssertTrue(hittable(app.buttons["Ship the remote Workbench"]))
  }

  @MainActor
  func testTappingTheConversationBesideTheMenuClosesIt() {
    let app = launch()
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(hittable(app.buttons["New chat"]))
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertTrue(menuClosed(app))
  }

  @MainActor
  func testAnOfflineMacCannotStartAChatAndAnOnlineOneDoes() {
    let app = launch(["AXO_PHONE_PREVIEW_HOSTS": "1"])
    XCTAssertTrue(accountShowing(app))
    XCTAssertFalse(app.buttons["Old iMac"].isEnabled)
    app.buttons["Studio"].tapWhereItIs()
    XCTAssertTrue(menuClosed(app))
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat")
  }

  @MainActor
  func testAMacIsRenamedFromTheAccountPanel() {
    let app = launch(["AXO_PHONE_PREVIEW_HOSTS": "1"])
    XCTAssertTrue(accountShowing(app))
    app.buttons["Rename Studio"].tapWhereItIs()
    let alert = app.alerts["Rename Mac"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    let field = alert.textFields.firstMatch
    field.tap()
    // The current name is there to edit; clear it and type another.
    XCTAssertEqual(field.value as? String, "Studio")
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "Leo's Studio")
    alert.buttons["Save"].tap()
    XCTAssertTrue(app.buttons["Leo's Studio"].waitForExistence(timeout: 5), "the row shows the new name at once")
    XCTAssertTrue(app.buttons["Rename Leo's Studio"].exists)
  }

  @MainActor
  func testAppsOpenFromTheAccountPanelAndATokenAccountIsAddedAfterARefusal() {
    let app = launch(["AXO_PHONE_PREVIEW_HOSTS": "1"])
    XCTAssertTrue(accountShowing(app))
    app.buttons["Apps"].tapWhereItIs()
    let gmail = app.buttons["Gmail"]
    XCTAssertTrue(gmail.waitForExistence(timeout: 10))
    XCTAssertEqual(gmail.value as? String, "Connected, 1 account", "connected apps come first")

    app.buttons["Hetzner"].tap()
    XCTAssertTrue(app.staticTexts["Needs a new token"].waitForExistence(timeout: 5) || app.staticTexts["Hetzner refused the token."].exists)
    app.buttons["Add account"].tap()
    let name = app.textFields["account-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText("work")
    let token = app.secureTextFields["token-field-token"]
    token.tap()
    token.typeText("bad")
    app.buttons["add-account"].tap()
    XCTAssertTrue(app.staticTexts["Hetzner refused that token."].waitForExistence(timeout: 5), "the service's own words")

    token.tap()
    token.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "good-token")
    app.buttons["add-account"].tap()
    XCTAssertTrue(app.staticTexts["work"].waitForExistence(timeout: 5), "the new account is listed")
    XCTAssertFalse(app.buttons["add-account"].exists, "the form is gone")
  }

  @MainActor
  func testADeviceSignInShowsItsCodeAndFinishesByItself() {
    let app = launch(["AXO_PHONE_PREVIEW_APPS": "1"])
    let chatgpt = app.buttons["ChatGPT"]
    XCTAssertTrue(chatgpt.waitForExistence(timeout: 10))
    chatgpt.tap()
    app.buttons["Add account"].tap()
    let code = app.staticTexts["device-code"]
    XCTAssertTrue(code.waitForExistence(timeout: 5))
    XCTAssertEqual(code.label, "Sign-in code WDJB-MJHT")
    XCTAssertTrue(app.staticTexts["leandro@example.com"].waitForExistence(timeout: 10), "signed in once the provider said so")
    XCTAssertFalse(code.exists)
  }

  @MainActor
  func testTelegramSignsInWithANumberACodeAndThePassword() {
    let app = launch(["AXO_PHONE_PREVIEW_APPS": "1"])
    XCTAssertTrue(app.buttons["Gmail"].waitForExistence(timeout: 10))
    // Below the fold: the list makes rows as they scroll in.
    let telegram = app.buttons["Telegram"]
    for _ in 0..<6 where !telegram.isHittable { app.swipeUp() }
    telegram.tap()
    app.buttons["Add account"].tap()
    let field = app.textFields["phone-sign-in-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("+44 7700 900123")
    app.buttons["phone-sign-in-next"].tap()

    let hint = app.staticTexts["phone-sign-in-hint"]
    XCTAssertTrue(hint.waitForExistence(timeout: 5))
    XCTAssertTrue(hint.label.contains("sent a code to your Telegram app"), hint.label)
    app.textFields["phone-sign-in-field"].tap()
    app.textFields["phone-sign-in-field"].typeText("00000")
    app.buttons["phone-sign-in-next"].tap()
    XCTAssertTrue(app.staticTexts["That code is not right. Enter the newest one."].waitForExistence(timeout: 5))
    app.textFields["phone-sign-in-field"].tap()
    app.textFields["phone-sign-in-field"].typeText("12345")
    app.buttons["phone-sign-in-next"].tap()

    let password = app.secureTextFields["phone-sign-in-field"]
    XCTAssertTrue(password.waitForExistence(timeout: 5), "the account has a password")
    XCTAssertTrue(hint.label.contains("Hint: pet."), hint.label)
    password.tap()
    password.typeText("hunter2")
    app.buttons["phone-sign-in-next"].tap()
    XCTAssertTrue(app.staticTexts["leostera"].waitForExistence(timeout: 5), "the account is listed")
    XCTAssertFalse(app.buttons["phone-sign-in-next"].exists, "the form is gone")
  }

  @MainActor
  func testTheMenuGroupsChatsByWorkspaceShowsEmptyOnesAndWhoIsWorking() {
    let app = launch(listing: "workspaces")
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(app.buttons["Axo · Studio"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Home · Old iMac"].exists)
    XCTAssertTrue(app.buttons["Website · Studio"].waitForExistence(timeout: 5), "a Workspace with no chats is listed")
    XCTAssertTrue(app.staticTexts["No chats yet"].exists)
    XCTAssertEqual(app.buttons["Ship the remote Workbench"].value as? String, "Working")
  }

  @MainActor
  func testHomeChatsAreListedUnderTheProjectsWithNoTitleOfTheirOwn() {
    let app = launch(listing: "workspaces")
    app.buttons["Chats menu"].tapWhereItIs()
    let lastProject = app.buttons["Website · Studio"]
    let newest = app.buttons["Plan the week"]
    let older = app.buttons["Draft the release notes"]
    XCTAssertTrue(newest.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Home · Studio"].exists, "the open Mac's Home has no folding title")
    XCTAssertGreaterThanOrEqual(newest.frame.minY, lastProject.frame.maxY, "under every project")
    XCTAssertGreaterThanOrEqual(older.frame.minY, newest.frame.maxY, "newest first")
  }

  @MainActor
  func testChatsQuietForEightHoursWaitBehindAButtonAndAWorkspaceFoldsAway() {
    let app = launch(listing: "workspaces")
    app.buttons["Chats menu"].tapWhereItIs()
    let older = app.buttons["Show 1 older chat"]
    XCTAssertTrue(older.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Photo library cleanup"].exists, "twelve days quiet: not listed")
    older.tapWhereItIs()
    XCTAssertTrue(app.buttons["Photo library cleanup"].waitForExistence(timeout: 5))
    app.buttons["Show fewer"].tapWhereItIs()
    XCTAssertTrue(waitUntil(5) { !app.buttons["Photo library cleanup"].exists })

    let axo = app.buttons["Axo · Studio"]
    XCTAssertEqual(axo.value as? String, "Expanded")
    axo.tapWhereItIs()
    XCTAssertTrue(waitUntil(5) { !app.buttons["Fix the sidebar spacing"].exists }, "a folded Workspace hides its chats")
    XCTAssertEqual(axo.value as? String, "Collapsed")
    axo.tapWhereItIs()
    XCTAssertTrue(app.buttons["Fix the sidebar spacing"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testTheMenuListsChatsAsTheMacDoesPinnedThenActiveThenEarlier() {
    var app = launch()
    // The listing is kept across launches: put it back for the other tests, however this one ends.
    addTeardownBlock { @MainActor in
      let back = XCUIApplication().buttons["Show recent chats"]
      if back.exists { back.tapWhereItIs() }
    }
    app.buttons["Chats menu"].tapWhereItIs()
    let toggle = app.buttons["chat-list-mode"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if toggle.label == "Show recent chats" { toggle.tapWhereItIs() }
    XCTAssertTrue(waitUntil(5) { toggle.label == "Show Workspaces" }, "listed as the Mac lists them by default")
    XCTAssertFalse(app.buttons["Axo · Studio"].exists, "no Workspace titles")
    // Active: working (or waiting on the person), unseen, or active in the last 3 minutes. Then
    // Earlier, by last message, offline Macs and quiet chats too.
    let active = app.buttons["chat-group-active"]
    let earlier = app.buttons["chat-group-earlier"]
    XCTAssertTrue(active.waitForExistence(timeout: 5))
    let order = ["Ship the remote Workbench", "Plan the week", "Fix the sidebar spacing", "Explain the relay",
      "Draft the release notes", "Photo library cleanup"]
    let rows = order.map { app.buttons[$0] }
    XCTAssertTrue(rows.last!.waitForExistence(timeout: 5))
    XCTAssertLessThan(active.frame.minY, rows[0].frame.minY)
    XCTAssertLessThan(rows[0].frame.minY, earlier.frame.minY, "the working chat is Active")
    XCTAssertLessThan(earlier.frame.minY, rows[1].frame.minY, "ten minutes quiet: Earlier")
    for (above, below) in zip(rows, rows.dropFirst()) {
      XCTAssertLessThan(above.frame.minY, below.frame.minY, "\(above.label) above \(below.label)")
    }
    XCTAssertTrue(app.staticTexts["10m"].exists, "each row says how long ago")
    XCTAssertTrue(app.staticTexts["1w"].exists)
    XCTAssertEqual(rows[0].value as? String, "on Studio, Working, 20 minutes ago", "with two Macs, each row says which")
    XCTAssertTrue((rows[5].value as? String)?.hasPrefix("on Old iMac, ") == true, "\(rows[5].value ?? "")")

    // Earlier folds away, and says how many chats it holds.
    XCTAssertEqual(earlier.value as? String, "Expanded")
    earlier.tapWhereItIs()
    XCTAssertTrue(waitUntil(5) { !app.buttons["Photo library cleanup"].exists }, "folded")
    XCTAssertTrue(app.staticTexts["5"].exists)
    earlier.tapWhereItIs()
    XCTAssertTrue(app.buttons["Photo library cleanup"].waitForExistence(timeout: 5))

    // A long press pins a chat to the top, with a pin at the end of its row.
    rows[4].press(forDuration: 0.8)
    let pin = app.buttons["Pin to the top"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    pin.tap()
    let pinned = app.buttons["chat-group-pinned"]
    XCTAssertTrue(pinned.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntil(5) { rows[4].frame.minY < active.frame.minY }, "pinned above Active")
    capture(app, named: "menu-grouped-light")
    XCTAssertTrue(
      waitUntil(5) { (rows[4].value as? String)?.hasPrefix("Pinned, on Studio") == true }, "\(rows[4].value ?? "")")
    capture(app, named: "menu-grouped-light")

    // In Workspaces, pinned chats lead too.
    toggle.tapWhereItIs()
    XCTAssertTrue(app.buttons["Axo · Studio"].waitForExistence(timeout: 5))
    XCTAssertLessThan(rows[4].frame.minY, app.buttons["Axo · Studio"].frame.minY)
    rows[4].press(forDuration: 0.8)
    XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 5))
    app.buttons["Unpin"].tap()
    XCTAssertTrue(waitUntil(5) { rows[4].frame.minY > app.buttons["Axo · Studio"].frame.minY }, "back in its Workspace")

    app.terminate()
    app = launch()
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(app.buttons["Show recent chats"].waitForExistence(timeout: 5), "kept across launches")
    XCTAssertTrue(app.buttons["Axo · Studio"].exists)
  }

  @MainActor
  func testChoosingAChatOpensItAndTheNewChatButtonLeavesIt() {
    let app = launch()
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(hittable(app.buttons["Fix the sidebar spacing"]))
    app.buttons["Fix the sidebar spacing"].tapWhereItIs()
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "Fix the sidebar spacing")
    XCTAssertTrue(app.staticTexts["I'll start with the menu."].waitForExistence(timeout: 5))
    XCTAssertTrue(menuClosed(app))
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(hittable(app.buttons["New chat"]))
    app.buttons["New chat"].tapWhereItIs()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(waitUntil(5) { title.label == "New chat" }, "title: \(title.label)")
  }

  @MainActor
  func testSearchFindsAChatByName() {
    let app = launch()
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(hittable(app.buttons["Search chats"]))
    app.buttons["Search chats"].tapWhereItIs()
    let field = app.textFields["search-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("relay")
    let result = app.buttons.matching(identifier: "search-result").firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    result.tapWhereItIs()
    XCTAssertTrue(app.staticTexts["Explain the relay"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "Explain the relay")
  }

  @MainActor
  func testSettingsOpenFromTheMenu() {
    let app = launch()
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(hittable(app.buttons["New chat"]))
    // The menu's button, not the account's under it (which UI tests still find).
    let settings = app.buttons.matching(NSPredicate(format: "label == 'Settings'")).allElementsBoundByIndex
      .first { $0.frame.width < 60 && $0.frame.minX >= 0 && $0.frame.maxX < 320 }
    XCTAssertNotNil(settings)
    settings?.tapWhereItIs()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    // Settings › Chats: how the list groups chats, as the Mac sets it.
    XCTAssertTrue(app.staticTexts["Active for"].exists || app.buttons["Active for"].exists)
    capture(app, named: "settings-chats-light")
    let signOut = app.buttons["Sign out"]
    for _ in 0..<4 where !signOut.isHittable { app.swipeUp() }
    XCTAssertTrue(signOut.isHittable)
  }

  // MARK: - Visual snapshots (compared against apple/AxoPhone/Snapshots/Phone, see Snapshots)

  @MainActor
  func testVisualSnapshotBlankChatLight() {
    let app = launch(appearance: "light")
    XCTAssertTrue(app.textFields["composer"].exists)
    Snapshots.check(app, named: "blank-chat-light", in: self)
  }

  @MainActor
  func testVisualSnapshotConversationDark() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1"], appearance: "dark")
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "Ship the remote Workbench")
    Snapshots.check(app, named: "conversation-dark", in: self)
  }

  @MainActor
  func testVisualSnapshotComposerWithKeyboard() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1"], appearance: "light")
    let composer = app.textFields["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText("Check the composer while the keyboard is open")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    Snapshots.check(app, named: "composer-keyboard-light", in: self)
  }

  /// A short, deterministic interaction sequence, ending on a snapshot.
  @MainActor
  func testVisualInteractionSequence() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1"], appearance: "dark")
    app.buttons["Chats menu"].tap()
    XCTAssertTrue(app.buttons["Fix the sidebar spacing"].waitForExistence(timeout: 5))
    app.buttons["Fix the sidebar spacing"].tap()
    let composer = app.textFields["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("A deterministic interaction recording")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    Snapshots.check(app, named: "interaction-composer-keyboard-dark", in: self)
  }

  // MARK: - Conversation

  @MainActor
  func testReturnStartsANewLineAndOnlySendSends() {
    let app = launch()
    let composer = app.textFields["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("First line\nSecond line")
    XCTAssertEqual(composer.value as? String, "First line\nSecond line", "Return added a line and sent nothing")
    XCTAssertEqual(app.staticTexts["conversation-title"].label, "New chat")
  }

  @MainActor
  func testAReplyBeingWrittenAndARunningToolShowAsTheyGrow() {
    let app = launch(["AXO_PHONE_PREVIEW_CHAT": "1", "AXO_PHONE_PREVIEW_LIVE": "reply"])
    XCTAssertTrue(app.staticTexts["Using tools…"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Still waiting on the")).firstMatch.exists)
    // A tool's output starts folded, saying how much there is and that it is still coming.
    let fold = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Show output (", "still running")).firstMatch
    XCTAssertTrue(fold.waitForExistence(timeout: 5))
    fold.tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "PhoneWorkbenchTests")).firstMatch.waitForExistence(timeout: 5),
      "unfolded, the output shows")
    XCTAssertTrue(app.buttons["Hide output"].exists)
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
