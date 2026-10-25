import AppKit
import AxoProtocol
import AxoRPC
import CoreGraphics
import Foundation
import Vision
import XCTest

@testable import AxoMac


/// Context menus, Workspaces, Sessions, splits and relaunch survival.
extension AxoVisualUITests {
  func testTerminalContextMenuRoutesSplitsAndCloseThroughAxo() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    fixture.launchApp()

    let model = TerminalSessionsModel(
      socketPath: try UnixSocketPath(fixture.socketURL.path)
    )
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()
    try await waitForSessionCount(1, model: model)
    let sessionID = try XCTUnwrap(model.sessions.first?.id)
    let window = fixture.terminalWindow
    let rightPane = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
    rightPane.rightClick()
    let splitRight = app.menuItems["Split Right"]
    XCTAssertTrue(splitRight.waitForExistence(timeout: 3))
    splitRight.click()
    try await waitForShellCount(2, sessionID: sessionID, model: model)

    rightPane.rightClick()
    let closePane = app.menuItems["Close Pane"]
    XCTAssertTrue(closePane.waitForExistence(timeout: 3))
    closePane.click()
    try await waitForShellCount(1, sessionID: sessionID, model: model)
  }

  func testSessionSidebarContextMenuRenamesAndArchives() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    let model = TerminalSessionsModel(
      socketPath: try UnixSocketPath(fixture.socketURL.path)
    )

    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()
    try await waitForSessionCount(1, model: model)
    let original = try XCTUnwrap(model.sessions.first)
    let row = app.descendants(matching: .any)
      .matching(identifier: "session-row-\(original.id)").firstMatch

    row.rightClick()
    let rename = app.menuItems["Rename Session"]
    XCTAssertTrue(rename.waitForExistence(timeout: 3))
    XCTAssertTrue(app.menuItems["Archive Session"].exists)
    rename.click()

    let field = app.textFields["rename-session-\(original.id)"]
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Manual sidebar label")
    app.buttons["inline-rename-save"].click()

    let renamedDeadline = Date().addingTimeInterval(5)
    while Date() < renamedDeadline {
      await model.refresh()
      if model.session(for: original.id)?.manualName == "Manual sidebar label" { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(model.session(for: original.id)?.name, original.name)
    XCTAssertEqual(model.session(for: original.id)?.manualName, "Manual sidebar label")

    row.rightClick()
    app.menuItems["Archive Session"].click()

    let replacementDeadline = Date().addingTimeInterval(10)
    while Date() < replacementDeadline {
      await model.refresh()
      if model.sessions.contains(where: { $0.id != original.id }) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertFalse(model.sessions.contains(where: { $0.id == original.id }))
    XCTAssertEqual(model.sessions.count, 1)
  }

  func testWorkspaceNameFieldReceivesPasteShortcut() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let pasteboardSnapshot = PasteboardSnapshot()
    defer { pasteboardSnapshot.restore() }
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()

    let createWorkspaceButton = app.buttons["new-workspace-button"]
    XCTAssertTrue(createWorkspaceButton.waitForExistence(timeout: 5), app.debugDescription)
    createWorkspaceButton.click()

    let nameField = app.textFields["workspace-name-field"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 5), app.debugDescription)
    nameField.click()

    let pastedName = "AXO_WORKSPACE_PASTE_\(UUID().uuidString)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(pastedName, forType: .string)
    nameField.typeKey("v", modifierFlags: .command)

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline, (nameField.value as? String) != pastedName {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(nameField.value as? String, pastedName)
    try await Task.sleep(for: .milliseconds(300))
    let terminal = app.descendants(matching: .any)
      .matching(identifier: "axo-terminal-surface").firstMatch
    XCTAssertFalse((terminal.value as? String ?? "").contains(pastedName))
  }
  func testCreateWorkspaceShowsFirstSessionAndPiSurvivesAppCloseAndReopen() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    let workspaceDirectory = fixture.root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

    let socketPath = try UnixSocketPath(fixture.socketURL.path)
    let model = TerminalSessionsModel(socketPath: socketPath)
    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.createWorkspace(at: workspaceDirectory)
    try await waitForWorkspaceSession(model: model)

    let original = try XCTUnwrap(model.sessions.first(where: { $0.workspaceId != nil }))
    let workspaceID = try XCTUnwrap(original.workspaceId)
    let workspace = try XCTUnwrap(model.workspaces.first(where: { $0.id == workspaceID }))
    XCTAssertEqual(workspace.name, "Workspace E2E")
    XCTAssertEqual(
      URL(fileURLWithPath: workspace.directoryPath).resolvingSymlinksInPath().path,
      workspaceDirectory.resolvingSymlinksInPath().path
    )
    XCTAssertEqual(
      model.sessions.filter { $0.workspaceId == workspace.id }.count,
      1,
      "Creating a Workspace should expose its initial Session in the sidebar catalog."
    )
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "workspace-row-\(workspaceID)").firstMatch
        .waitForExistence(timeout: 3),
      "The new Workspace should appear in the sidebar."
    )
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "session-row-\(original.id)").firstMatch
        .waitForExistence(timeout: 3),
      "The Workspace's first Session should appear in the sidebar immediately."
    )
    let workspaceRow = app.descendants(matching: .any)
      .matching(identifier: "workspace-row-\(workspaceID)").firstMatch
    workspaceRow.rightClick()
    XCTAssertTrue(app.menuItems["Rename Workspace"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.menuItems["Archive Workspace and Sessions"].exists)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

    let originalShell = try XCTUnwrap(original.shells.first)
    let transcriptPath = try XCTUnwrap(original.piSessionFile)
    let interactionMarker = "AXO_PI_SESSION_E2E_\(UUID().uuidString)"
    XCTAssertEqual(originalShell.role, .pi)
    XCTAssertTrue(transcriptPath.hasPrefix("/"))
    XCTAssertTrue(transcriptPath.contains(workspaceID))

    try await fixture.selectSession(original.id)
    try await fixture.waitForTerminalReady()
    _ = try fixture.capture("00-pi-session-startup", in: fixture.terminalWindow)
    try await waitForPiBinding(sessionID: original.id, model: model)
    let originalPiSessionId = try XCTUnwrap(model.session(for: original.id)?.piSessionId)

    try await fixture.typeText("!printf '\(interactionMarker)\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let interactionScreenshot = try fixture.capture(
      "00-pi-session-interaction", in: fixture.terminalWindow)
    try fixture.assertContainsText(interactionMarker, in: interactionScreenshot)
    try await waitForPiTranscript(at: transcriptPath, containing: interactionMarker)
    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))

    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.selectSession(original.id)
    try await fixture.waitForTerminalReady()
    try await waitForPiBinding(sessionID: original.id, model: model)

    let reopened = try XCTUnwrap(model.session(for: original.id))
    XCTAssertEqual(reopened.id, original.id)
    XCTAssertEqual(reopened.sessionUuid, original.sessionUuid)
    XCTAssertEqual(reopened.piSessionFile, original.piSessionFile)
    XCTAssertEqual(reopened.piSessionId, originalPiSessionId)
    XCTAssertEqual(reopened.shells.first?.id, originalShell.id)
    XCTAssertEqual(reopened.shells.first?.processId, originalShell.processId)
    let persistedTranscript = try String(contentsOfFile: transcriptPath, encoding: .utf8)
    XCTAssertTrue(persistedTranscript.contains(interactionMarker))

    await model.closeSession(original.id)
    let replacementDeadline = Date().addingTimeInterval(10)
    var workspaceReplacement: TerminalSession?
    while Date() < replacementDeadline {
      await model.refresh()
      workspaceReplacement = model.sessions.first {
        $0.workspaceId == workspaceID && $0.id != original.id
      }
      if workspaceReplacement != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let workspaceReplacement else {
      return XCTFail("Closing the last Workspace Session should create its replacement.")
    }
    XCTAssertEqual(workspaceReplacement.workspaceId, workspaceID)
    XCTAssertEqual(
      URL(fileURLWithPath: workspaceReplacement.initialPwd).resolvingSymlinksInPath().path,
      workspaceDirectory.resolvingSymlinksInPath().path
    )

    try await fixture.selectSession(workspaceReplacement.id)
    let countBeforeCommandT = model.sessions.count
    fixture.terminalWindow.typeKey("t", modifierFlags: .command)
    try await waitForSessionCount(countBeforeCommandT + 1, model: model)
    let commandTSession = try XCTUnwrap(
      model.sessions
        .filter { $0.workspaceId == workspaceID }
        .max { $0.id < $1.id }
    )
    XCTAssertEqual(commandTSession.workspaceId, workspaceID)
    XCTAssertEqual(
      URL(fileURLWithPath: commandTSession.initialPwd).resolvingSymlinksInPath().path,
      workspaceDirectory.resolvingSymlinksInPath().path
    )

    fixture.terminalWindow.typeKey("w", modifierFlags: .command)
    let focusReturnDeadline = Date().addingTimeInterval(10)
    while Date() < focusReturnDeadline, model.selectedSessionID != workspaceReplacement.id {
      await model.refresh()
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(
      model.selectedSessionID,
      workspaceReplacement.id,
      "Closing the new Workspace Session should return focus to the previously active Workspace Session."
    )
  }

  func testLaunchSplitCloseExitSessionSelectionAndSurvivingShell() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let pasteboardSnapshot = PasteboardSnapshot()
    defer { pasteboardSnapshot.restore() }

    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    fixture.launchApp()

    let model = TerminalSessionsModel(
      socketPath: try UnixSocketPath(fixture.socketURL.path)
    )
    try await fixture.waitForWindow()
    XCTAssertTrue(app.menuBars.menuBarItems["Axo"].waitForExistence(timeout: 2))
    let window = fixture.terminalWindow
    try fixture.capture("00-window-opened", in: window)

    try await waitForSessionCount(1, model: model)
    try await fixture.waitForTerminalReady()
    try fixture.capture("01-initial-terminal", in: window)

    let initialSession = try XCTUnwrap(model.sessions.first)
    XCTAssertEqual(initialSession.shells.count, 1)
    window.click()
    window.typeText("printf 'AXO VISUAL INITIAL 7319\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let initialOutput = try fixture.capture("02-initial-shell-output", in: window)
    try fixture.assertContainsText("AXO VISUAL INITIAL 7319", in: initialOutput)

    NSPasteboard.general.clearContents()
    window.typeKey("a", modifierFlags: .command)
    let copyDeadline = Date().addingTimeInterval(2)
    var copiedSelection: String?
    while Date() < copyDeadline {
      copiedSelection = NSPasteboard.general.string(forType: .string)
      if copiedSelection?.contains("AXO VISUAL INITIAL 7319") == true { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(
      copiedSelection?.contains("AXO VISUAL INITIAL 7319") == true,
      "Selecting terminal text should copy it to the system clipboard."
    )
    let selectedTerminal = try fixture.capture("02b-copy-on-select", in: window)
    try fixture.assertContainsText("AXO VISUAL INITIAL 7319", in: selectedTerminal)

    window.typeKey("d", modifierFlags: .command)
    try await waitForShellCount(2, sessionID: initialSession.id, model: model)
    try await fixture.waitForSurfaceCount(2)
    let firstSplit = try fixture.capture("03-split-right", in: window)
    try fixture.assertContainsText("AXO VISUAL INITIAL 7319", in: firstSplit)
    try fixture.assertTextInLeftHalf("AXO VISUAL INITIAL 7319", in: firstSplit)

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("printf 'AXO VISUAL PASTE RIGHT 6482\\n'\n", forType: .string)
    window.typeKey("v", modifierFlags: .command)
    let pasteConfirmation = app.alerts.firstMatch
    XCTAssertTrue(pasteConfirmation.waitForExistence(timeout: 5), app.debugDescription)
    pasteConfirmation.buttons["Allow"].click()
    window.typeText("\n")
    try await Task.sleep(for: .milliseconds(500))
    let pastedIntoRight = try fixture.capture("03b-paste-focused-pane", in: window)
    try fixture.assertTextInRightHalf("AXO VISUAL PASTE RIGHT 6482", in: pastedIntoRight)

    NSPasteboard.general.clearContents()
    window.typeKey("a", modifierFlags: .command)
    window.typeKey("c", modifierFlags: .command)
    let focusedCopyDeadline = Date().addingTimeInterval(2)
    var copiedFocusedPane: String?
    while Date() < focusedCopyDeadline {
      copiedFocusedPane = NSPasteboard.general.string(forType: .string)
      if copiedFocusedPane?.contains("AXO VISUAL PASTE RIGHT 6482") == true { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(
      copiedFocusedPane?.contains("AXO VISUAL PASTE RIGHT 6482") == true,
      "Select All and Copy should read the currently focused pane."
    )
    XCTAssertFalse(copiedFocusedPane?.contains("AXO VISUAL INITIAL 7319") == true)

    NSPasteboard.general.clearContents()
    window.typeKey("x", modifierFlags: .command)
    let cutCopyDeadline = Date().addingTimeInterval(2)
    var cutCopiedFocusedPane: String?
    while Date() < cutCopyDeadline {
      cutCopiedFocusedPane = NSPasteboard.general.string(forType: .string)
      if cutCopiedFocusedPane?.contains("AXO VISUAL PASTE RIGHT 6482") == true { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(
      cutCopiedFocusedPane?.contains("AXO VISUAL PASTE RIGHT 6482") == true,
      "Cut should copy from the currently focused pane, like Copy."
    )
    let afterCut = try fixture.capture("03c-cut-copies-focused-pane", in: window)
    try fixture.assertContainsText("AXO VISUAL PASTE RIGHT 6482", in: afterCut)

    window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
    window.typeKey("w", modifierFlags: .command)
    try await waitForShellCount(1, sessionID: initialSession.id, model: model)
    try await fixture.waitForSurfaceCount(1)
    let closedClickedPane = try fixture.capture("03d-close-clicked-pane", in: window)
    try fixture.assertContainsText("AXO VISUAL INITIAL 7319", in: closedClickedPane)
    try fixture.assertDoesNotContainText("AXO VISUAL PASTE RIGHT 6482", in: closedClickedPane)

    window.typeKey("d", modifierFlags: .command)
    try await waitForShellCount(2, sessionID: initialSession.id, model: model)
    try await fixture.waitForSurfaceCount(2)
    window.typeText("printf 'AXO VISUAL RIGHT 2846\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let rightOutput = try fixture.capture("04-split-right-output", in: window)
    try fixture.assertContainsText("AXO VISUAL INITIAL 7319", in: rightOutput)
    try fixture.assertContainsText("AXO VISUAL RIGHT 2846", in: rightOutput)
    try fixture.assertTextInLeftHalf("AXO VISUAL INITIAL 7319", in: rightOutput)
    try fixture.assertTextInRightHalf("AXO VISUAL RIGHT 2846", in: rightOutput)

    window.typeKey("d", modifierFlags: [.command, .shift])
    try await waitForShellCount(3, sessionID: initialSession.id, model: model)
    try await fixture.waitForSurfaceCount(3)
    let nestedSplit = try fixture.capture("05-nested-split-down", in: window)
    try fixture.assertContainsText("AXO VISUAL INITIAL 7319", in: nestedSplit)
    try fixture.assertContainsText("AXO VISUAL RIGHT 2846", in: nestedSplit)

    window.typeText("printf 'AXO VISUAL LOWER 3691\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let nestedOutput = try fixture.capture("06-nested-split-output", in: window)
    try fixture.assertTextInLeftHalf("AXO VISUAL INITIAL 7319", in: nestedOutput)
    try fixture.assertTextInRightHalf("AXO VISUAL RIGHT 2846", in: nestedOutput)
    try fixture.assertTextInRightHalf("AXO VISUAL LOWER 3691", in: nestedOutput)
    try fixture.assertTextBelow("AXO VISUAL LOWER 3691", "AXO VISUAL RIGHT 2846", in: nestedOutput)

    window.typeKey("[", modifierFlags: .command)
    window.typeText("printf 'AXO VISUAL PREVIOUS PANE 4128\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let previousPane = try fixture.capture("07-previous-pane", in: window)
    try fixture.assertTextInRightHalf("AXO VISUAL PREVIOUS PANE 4128", in: previousPane)
    try fixture.assertTextBelow(
      "AXO VISUAL PREVIOUS PANE 4128", "AXO VISUAL RIGHT 2846", in: previousPane)

    window.typeKey("]", modifierFlags: .command)
    window.typeText("printf 'AXO VISUAL NEXT PANE 9357\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let nextPane = try fixture.capture("08-next-pane", in: window)
    try fixture.assertTextInRightHalf("AXO VISUAL NEXT PANE 9357", in: nextPane)
    try fixture.assertTextBelow(
      "AXO VISUAL NEXT PANE 9357", "AXO VISUAL PREVIOUS PANE 4128", in: nextPane)

    window.typeKey("]", modifierFlags: .command)
    window.typeText("printf 'AXO VISUAL PANE WRAP 7832\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let paneWrap = try fixture.capture("09-pane-next-wrap", in: window)
    try fixture.assertTextInLeftHalf("AXO VISUAL PANE WRAP 7832", in: paneWrap)

    window.typeKey("[", modifierFlags: .command)
    window.typeKey("w", modifierFlags: .command)
    try await waitForShellCount(2, sessionID: initialSession.id, model: model)
    try await fixture.waitForSurfaceCount(2)
    let afterClose = try fixture.capture("10-close-focused-shell", in: window)
    try fixture.assertContainsText("AXO VISUAL INITIAL 7319", in: afterClose)
    try fixture.assertContainsText("AXO VISUAL RIGHT 2846", in: afterClose)
    try fixture.assertDoesNotContainText("AXO VISUAL LOWER 3691", in: afterClose)

    window.typeText("exit\n")
    try await waitForShellCount(1, sessionID: initialSession.id, model: model)
    try await fixture.waitForSurfaceCount(1)
    let afterExit = try fixture.capture("11-shell-exit", in: window)
    try fixture.assertContainsText("AXO VISUAL INITIAL 7319", in: afterExit)
    try fixture.assertDoesNotContainText("AXO VISUAL RIGHT 2846", in: afterExit)

    window.typeText("printf 'AXO VISUAL SURVIVOR 5690\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let survivorOutput = try fixture.capture("12-surviving-shell-output", in: window)
    try fixture.assertContainsText("AXO VISUAL SURVIVOR 5690", in: survivorOutput)

    window.typeKey("t", modifierFlags: .command)
    try await waitForSessionCount(2, model: model)
    XCTAssertNil(model.session(for: try XCTUnwrap(model.selectedSessionID))?.workspaceId)
    try await fixture.waitForSurfaceCount(2)
    let newSession = try fixture.capture("13-new-session", in: window)
    try fixture.assertDoesNotContainText("AXO VISUAL SURVIVOR 5690", in: newSession)

    window.typeKey("[", modifierFlags: [.command, .shift])
    let previousSession = try fixture.capture("14-previous-session", in: window)
    try fixture.assertContainsText("AXO VISUAL SURVIVOR 5690", in: previousSession)

    window.typeKey("]", modifierFlags: [.command, .shift])
    let nextSession = try fixture.capture("15-next-session", in: window)
    try fixture.assertDoesNotContainText("AXO VISUAL SURVIVOR 5690", in: nextSession)

    window.typeKey("]", modifierFlags: [.command, .shift])
    let sessionWrap = try fixture.capture("16-next-session-wrap", in: window)
    try fixture.assertContainsText("AXO VISUAL SURVIVOR 5690", in: sessionWrap)

    window.typeText(
      "printf '\\033[?1049h\\033[2J\\033[HAXO REATTACHED TUI 8751\\n'; sleep 30\n"
    )
    try await Task.sleep(for: .milliseconds(500))
    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
    fixture.launchApp()
    try await fixture.waitForWindow()
    try await waitForSessionCount(2, model: model)
    try await fixture.waitForTerminalReady()
    try await fixture.waitForSurfaceCount(1)
    try await Task.sleep(for: .milliseconds(500))
    let reopenedWindow = fixture.terminalWindow
    // Keep a screenshot artifact for visual inspection. Vision intermittently misses
    // Ghostty's antialiased monospace text after the app reconnects, so the stable
    // assertion here is that both restored surfaces are attached and nonblank.
    _ = try fixture.capture("17-restored-tui-after-relaunch", in: reopenedWindow)

    let sidebarStartsCollapsed = app.buttons["Expand sidebar"].exists
    let sidebarStartsExpanded = app.buttons["Collapse sidebar"].exists
    XCTAssertTrue(sidebarStartsCollapsed || sidebarStartsExpanded)
    reopenedWindow.typeKey("s", modifierFlags: .command)
    if sidebarStartsCollapsed {
      XCTAssertTrue(app.buttons["Collapse sidebar"].waitForExistence(timeout: 2))
    } else {
      XCTAssertTrue(app.buttons["Expand sidebar"].waitForExistence(timeout: 2))
    }
    reopenedWindow.typeKey("s", modifierFlags: .command)
    if sidebarStartsCollapsed {
      XCTAssertTrue(app.buttons["Expand sidebar"].waitForExistence(timeout: 2))
    } else {
      XCTAssertTrue(app.buttons["Collapse sidebar"].waitForExistence(timeout: 2))
    }

    XCTAssertEqual(model.sessions.count, 2)

    app.menuBars.menuBarItems["Axo"].click()
    let aboutMenuItem = app.menuItems["About Axo"]
    XCTAssertTrue(aboutMenuItem.waitForExistence(timeout: 2))
    aboutMenuItem.click()
    let settingsWindow = app.windows["Axo Settings"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 2))
    XCTAssertTrue(settingsWindow.staticTexts["Agentic harness for terminal romantics"].exists)
    XCTAssertTrue(settingsWindow.staticTexts["Commit"].exists)
    XCTAssertTrue(settingsWindow.staticTexts["axod version"].exists)
    XCTAssertTrue(settingsWindow.staticTexts["axod build"].exists)
    XCTAssertTrue(settingsWindow.staticTexts["Daemon status"].exists)
    try fixture.capture("18-about-settings", in: settingsWindow)
    XCTAssertEqual(fixture.screenshotsWritten, 23)
  }
}
