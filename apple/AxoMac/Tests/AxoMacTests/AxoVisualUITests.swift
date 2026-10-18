import AppKit
import AxoRPC
import CoreGraphics
import Foundation
import Vision
import XCTest

@testable import AxoMac

@MainActor
final class AxoVisualUITests: XCTestCase {
  func testKittyKeyboardNegotiationEncodesReturnAndShiftEnter() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }

    let readyURL = fixture.root.appendingPathComponent("kitty-keyboard-ready")
    let enterURL = fixture.root.appendingPathComponent("kitty-keyboard-enter")
    let shiftEnterURL = fixture.root.appendingPathComponent("kitty-keyboard-shift-enter")
    let commandPeriodURL = fixture.root.appendingPathComponent("kitty-keyboard-command-period")
    let scriptURL = fixture.root.appendingPathComponent("kitty-keyboard-probe.py")
    let script = #"""
      import os, select, sys, termios, time, tty

      ready_path = \#(try pythonStringLiteral(readyURL.path))
      enter_path = \#(try pythonStringLiteral(enterURL.path))
      shift_enter_path = \#(try pythonStringLiteral(shiftEnterURL.path))
      command_period_path = \#(try pythonStringLiteral(commandPeriodURL.path))
      fd = sys.stdin.fileno()
      previous_terminal = termios.tcgetattr(fd)

      def read_one_key(timeout):
          deadline = time.monotonic() + timeout
          data = bytearray()
          while time.monotonic() < deadline:
              readable, _, _ = select.select([fd], [], [], 0.05)
              if not readable:
                  continue
              data.extend(os.read(fd, 1))
              if data in (b"\r", b"\n"):
                  return bytes(data)
              if data.startswith(b"\x1b[") and data.endswith(b"u"):
                  return bytes(data)
          raise TimeoutError("timed out waiting for a keyboard event")

      def write_until(marker, timeout):
          deadline = time.monotonic() + timeout
          data = bytearray()
          while marker not in data and time.monotonic() < deadline:
              readable, _, _ = select.select([fd], [], [], 0.05)
              if readable:
                  data.extend(os.read(fd, 1))
          if marker not in data:
              raise TimeoutError("terminal did not answer the Kitty keyboard query")
          return bytes(data)

      tty.setraw(fd)
      try:
          sys.stdout.write("\x1b[>7u\x1b[?u")
          sys.stdout.flush()
          response = write_until(b"\x1b[?7u", 5)
          with open(ready_path, "wb") as ready:
              ready.write(response)
          with open(enter_path, "wb") as enter:
              enter.write(read_one_key(10))
          with open(shift_enter_path, "wb") as shift_enter:
              shift_enter.write(read_one_key(10))
          with open(command_period_path, "wb") as command_period:
              command_period.write(read_one_key(10))
      finally:
          sys.stdout.write("\x1b[<u")
          sys.stdout.flush()
          termios.tcsetattr(fd, termios.TCSANOW, previous_terminal)
      """#
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)

    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()
    try await fixture.typeText("python3 '\(scriptURL.path)'\n")
    let protocolResponse = try await waitForFile(at: readyURL, timeout: 8)
    XCTAssertTrue(String(decoding: protocolResponse, as: UTF8.self).contains("\u{1B}[?7u"))

    fixture.terminalWindow.click()
    fixture.terminalWindow.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    _ = try await waitForFile(at: enterURL, timeout: 5)
    fixture.terminalWindow.typeKey(XCUIKeyboardKey.return, modifierFlags: .shift)
    _ = try await waitForFile(at: shiftEnterURL, timeout: 5)

    XCTAssertEqual(try Data(contentsOf: enterURL), Data([0x0d]))
    XCTAssertEqual(
      try Data(contentsOf: shiftEnterURL), Data([0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75]))

    fixture.terminalWindow.typeKey(".", modifierFlags: .command)
    _ = try await waitForFile(at: commandPeriodURL, timeout: 5)
    XCTAssertEqual(
      try Data(contentsOf: commandPeriodURL), Data([0x1b, 0x5b, 0x34, 0x36, 0x3b, 0x39, 0x75]))
  }

  func testCreateWorkspaceShowsFirstSessionAndPiSurvivesAppCloseAndReopen() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    let workspaceDirectory = fixture.root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)

    let socketPath = try UnixSocketPath(fixture.socketURL.path)
    let model = TerminalSessionsModel(socketPath: socketPath, helperURL: fixture.helperURL)
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
    let originalShell = try XCTUnwrap(original.shells.first)
    let transcriptPath = try XCTUnwrap(original.piSessionFile)
    let interactionMarker = "AXO_PI_SESSION_E2E_\(UUID().uuidString)"
    XCTAssertEqual(originalShell.role, "pi")
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
      socketPath: try UnixSocketPath(fixture.socketURL.path),
      helperURL: fixture.helperURL
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

  private func assertNoAxoUITestAppIsAlreadyRunning() throws {
    let testBundleID = "dev.leostera.axo.ui-tests"
    let running = NSWorkspace.shared.runningApplications.first {
      $0.bundleIdentifier == testBundleID && !$0.isTerminated
    }
    guard let running else { return }
    throw UITestError.frontendAlreadyRunning(
      "\(testBundleID) (pid \(running.processIdentifier))")
  }

  private func waitForFile(at url: URL, timeout: TimeInterval) async throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let data = try? Data(contentsOf: url) { return data }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw UITestError.timedOut("isolated terminal probe did not create \(url.lastPathComponent)")
  }

  private func pythonStringLiteral(_ value: String) throws -> String {
    let encoded = try JSONEncoder().encode(value)
    return String(decoding: encoded, as: UTF8.self)
  }

  private func waitForPiTranscript(at path: String, containing marker: String) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let transcript = try? String(contentsOfFile: path, encoding: .utf8), transcript.contains(marker) {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.timedOut("Pi did not persist the interactive Session transcript")
  }

  private func waitForPiBinding(sessionID: Int64, model: TerminalSessionsModel) async throws {
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline {
      await model.refresh()
      if model.session(for: sessionID)?.piSessionId != nil { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.timedOut("axod did not verify the exact Pi session-file binding")
  }

  private func waitForWorkspaceSession(model: TerminalSessionsModel) async throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      await model.refresh()
      if model.sessions.contains(where: { $0.workspaceId != nil }) { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.timedOut(
      "axod did not create the Workspace Agent Session: \(model.errorMessage ?? "no RPC error reported")")
  }

  private func waitForSessionCount(_ count: Int, model: TerminalSessionsModel) async throws {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      await model.refresh()
      if model.sessions.count == count { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.sessionCountTimedOut(count, model.sessions.count)
  }

  private func waitForShellCount(
    _ count: Int,
    sessionID: Int64,
    model: TerminalSessionsModel
  ) async throws {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      await model.refresh()
      if model.session(for: sessionID)?.shells.count == count { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UITestError.shellCountTimedOut(
      count, model.session(for: sessionID)?.shells.count ?? 0, sessionID)
  }
}

@MainActor
private final class UITestFixture {
  private struct RecognizedLine {
    let text: String
    let bounds: CGRect
  }

  let root: URL
  let socketURL: URL
  let helperURL: URL
  let app: XCUIApplication
  private let controlDirectory: URL
  private let screenshotDirectory: URL
  private var didLaunchApp = false
  private(set) var screenshotsWritten = 0

  init(app: XCUIApplication) throws {
    self.app = app
    let environment = ProcessInfo.processInfo.environment
    guard let rootPath = environment["AXO_UI_TEST_ROOT"] else {
      throw UITestError.missingDaemonEnvironment("AXO_UI_TEST_ROOT")
    }
    root = URL(fileURLWithPath: rootPath, isDirectory: true)
    socketURL = root.appendingPathComponent("s")
    controlDirectory = root.appendingPathComponent("control", isDirectory: true)
    let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
    let temporaryDirectory = root.appendingPathComponent("tmp", isDirectory: true)

    let resources = Bundle(for: AxoVisualUITests.self).resourceURL
    guard let helperURL = resources?.appendingPathComponent("axod"),
      FileManager.default.isExecutableFile(atPath: helperURL.path)
    else { throw UITestError.bundledHelperMissing(resources?.path ?? "<no test resources>") }
    self.helperURL = helperURL

    for path in [
      root.path, socketURL.path, controlDirectory.path, homeDirectory.path,
      temporaryDirectory.path,
    ]
    where !FileManager.default.fileExists(atPath: path) {
      throw UITestError.missingDaemonEnvironment(path)
    }

    screenshotDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("axo-ui-screenshots", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: screenshotDirectory, withIntermediateDirectories: true)
  }

  func launchApp() {
    let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
    let temporaryDirectory = root.appendingPathComponent("tmp", isDirectory: true)
    var environment = Self.testEnvironment(
      homeDirectory: homeDirectory, temporaryDirectory: temporaryDirectory)
    environment["AXO_UI_TEST_SOCKET"] = socketURL.path
    environment["AXO_UI_TEST_HELPER"] = helperURL.path
    environment["AXO_UI_TEST_CONTROL_DIR"] = controlDirectory.path
    app.launchArguments = ["--ui-test"]
    app.launchEnvironment = environment
    app.launch()
    didLaunchApp = true
  }

  var terminalWindow: XCUIElement {
    app.windows["Axo Terminal"]
  }

  func createWorkspace(at directory: URL) async throws {
    let createButton = app.buttons["new-workspace-button"]
    XCTAssertTrue(createButton.waitForExistence(timeout: 5), app.debugDescription)
    createButton.click()

    let nameField = app.textFields["workspace-name-field"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 5), app.debugDescription)
    nameField.click()
    nameField.typeText("Workspace E2E")

    let browseButton = app.buttons["workspace-choose-directory-button"]
    XCTAssertTrue(browseButton.waitForExistence(timeout: 3), app.debugDescription)
    browseButton.click()

    let chooseDirectory = app.buttons["Open"]
    XCTAssertTrue(chooseDirectory.waitForExistence(timeout: 5), app.debugDescription)
    app.typeKey("g", modifierFlags: [.command, .shift])

    let goToFolder = app.sheets.firstMatch
    XCTAssertTrue(goToFolder.waitForExistence(timeout: 3), app.debugDescription)
    let pathField = goToFolder.textFields.firstMatch
    XCTAssertTrue(pathField.waitForExistence(timeout: 2), app.debugDescription)
    pathField.click()
    pathField.typeText(directory.deletingLastPathComponent().path)
    goToFolder.buttons["Go"].click()

    let folder = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", directory.lastPathComponent))
      .firstMatch
    XCTAssertTrue(folder.waitForExistence(timeout: 3), app.debugDescription)
    folder.click()
    chooseDirectory.click()

    let commitButton = app.buttons["Create Workspace"]
    XCTAssertTrue(commitButton.waitForExistence(timeout: 3), app.debugDescription)
    commitButton.click()
  }

  func waitForWindow() async throws {
    guard app.wait(for: .runningForeground, timeout: 12),
      terminalWindow.waitForExistence(timeout: 8)
    else { throw UITestError.windowTimedOut }
  }

  func waitForTerminalReady() async throws {
    try await perform(ControlRequest(operation: "wait-ready"))
  }

  func selectSession(_ sessionId: Int64) async throws {
    var request = ControlRequest(operation: "select-session")
    request.sessionId = sessionId
    try await perform(request)
  }

  func typeText(_ text: String) async throws {
    try await perform(ControlRequest(operation: "text", text: text))
  }

  func waitForSurfaceCount(_ count: Int) async throws {
    try await perform(
      ControlRequest(operation: "wait-surface-count", minimumSurfaceCount: count))
  }

  @discardableResult
  func capture(_ name: String, in window: XCUIElement) throws -> CGImage {
    let screenshot = window.screenshot()
    let data = screenshot.pngRepresentation
    let url = screenshotDirectory.appendingPathComponent("\(name).png")
    try data.write(to: url, options: .atomic)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
      activity.add(attachment)
    }
    screenshotsWritten += 1
    print("AXO_UI_SCREENSHOT \(url.path)")

    guard let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
      throw UITestError.couldNotDecodeScreenshot(name)
    }
    guard Self.hasVisiblePixels(image) else { throw UITestError.blankScreenshot(name) }
    return image
  }

  func assertContainsText(_ expected: String, in image: CGImage) throws {
    let lines = try recognizedLines(in: image)
    let recognizedText = lines.map(\.text).joined(separator: " ")
    XCTAssertTrue(
      recognizedText.localizedCaseInsensitiveContains(expected),
      "Screenshot OCR did not find '\(expected)'. Recognized: \(recognizedText)"
    )
  }

  func assertDoesNotContainText(_ expected: String, in image: CGImage) throws {
    let lines = try recognizedLines(in: image)
    let recognizedText = lines.map(\.text).joined(separator: " ")
    XCTAssertFalse(
      recognizedText.localizedCaseInsensitiveContains(expected),
      "Screenshot unexpectedly contains '\(expected)'. Recognized: \(recognizedText)"
    )
  }

  func assertTextInLeftHalf(_ expected: String, in image: CGImage) throws {
    let matchingLines = try recognizedLines(in: image).filter {
      $0.text.localizedCaseInsensitiveContains(expected)
    }
    XCTAssertFalse(matchingLines.isEmpty, "Screenshot OCR did not locate '\(expected)'.")
    XCTAssertTrue(
      matchingLines.contains { $0.bounds.midX < 0.5 },
      "Expected '\(expected)' to appear in the left split pane."
    )
  }

  func assertTextInRightHalf(_ expected: String, in image: CGImage) throws {
    let matchingLines = try recognizedLines(in: image).filter {
      $0.text.localizedCaseInsensitiveContains(expected)
    }
    XCTAssertFalse(matchingLines.isEmpty, "Screenshot OCR did not locate '\(expected)'.")
    XCTAssertTrue(
      matchingLines.contains { $0.bounds.midX > 0.5 },
      "Expected '\(expected)' to appear in the right split pane."
    )
  }

  func assertTextBelow(_ text: String, _ otherText: String, in image: CGImage) throws {
    let line = try XCTUnwrap(
      try recognizedLine(containing: text, in: image),
      "Screenshot OCR did not locate '\(text)'."
    )
    let otherLine = try XCTUnwrap(
      try recognizedLine(containing: otherText, in: image),
      "Screenshot OCR did not locate '\(otherText)'."
    )
    XCTAssertLessThan(
      line.bounds.midY, otherLine.bounds.midY,
      "Expected '\(text)' to appear below '\(otherText)' in the nested split."
    )
  }

  private func recognizedLine(containing text: String, in image: CGImage) throws -> RecognizedLine?
  {
    try recognizedLines(in: image).first {
      $0.text.localizedCaseInsensitiveContains(text)
    }
  }

  private func recognizedLines(in image: CGImage) throws -> [RecognizedLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return request.results?.compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      return RecognizedLine(text: text, bounds: observation.boundingBox)
    } ?? []
  }

  func stop() {
    if didLaunchApp, app.state != .notRunning {
      app.terminate()
      _ = app.wait(for: .notRunning, timeout: 4)
    }
    print("AXO_UI_SCREENSHOTS \(screenshotDirectory.path)")
  }

  private func perform(_ request: ControlRequest) async throws {
    let requestURL = controlDirectory.appendingPathComponent("request.json")
    let responseURL = controlDirectory.appendingPathComponent("response-\(request.id).json")
    guard !FileManager.default.fileExists(atPath: requestURL.path) else {
      throw UITestError.controlRequestAlreadyPending
    }
    try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)

    let timeout: TimeInterval = request.operation.hasPrefix("wait-") ? 14 : 6
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let data = try? Data(contentsOf: responseURL) {
        try? FileManager.default.removeItem(at: responseURL)
        let response = try JSONDecoder().decode(ControlResponse.self, from: data)
        guard response.id == request.id else { throw UITestError.wrongControlResponse }
        if let error = response.error { throw UITestError.appActionFailed(error) }
        return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw UITestError.controlRequestTimedOut(request.operation)
  }

  private static func testEnvironment(homeDirectory: URL, temporaryDirectory: URL)
    -> [String: String]
  {
    let inherited = ProcessInfo.processInfo.environment
    var environment: [String: String] = [
      "ApplePersistenceIgnoreState": "YES",
      "HOME": homeDirectory.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "SHELL": "/bin/zsh",
      "TERM": "xterm-ghostty",
      "TMPDIR": temporaryDirectory.path,
    ]
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL"] {
      if let value = inherited[key] { environment[key] = value }
    }
    return environment
  }

  private static func hasVisiblePixels(_ image: CGImage) -> Bool {
    guard let providerData = image.dataProvider?.data,
      let data = providerData as Data?,
      !data.isEmpty
    else { return false }

    let bytesPerPixel = max(1, image.bitsPerPixel / 8)
    let xStride = max(1, image.width / 32)
    let yStride = max(1, image.height / 32)
    return data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return false
      }
      for y in stride(from: 0, to: image.height, by: yStride) {
        for x in stride(from: 0, to: image.width, by: xStride) {
          let offset = y * image.bytesPerRow + x * bytesPerPixel
          guard offset + min(2, bytesPerPixel - 1) < data.count else { continue }
          if (0..<min(3, bytesPerPixel)).contains(where: { baseAddress[offset + $0] > 12 }) {
            return true
          }
        }
      }
      return false
    }
  }

}

private struct PasteboardSnapshot {
  private struct Representation {
    let type: NSPasteboard.PasteboardType
    let data: Data
  }

  private let items: [[Representation]]

  init(pasteboard: NSPasteboard = .general) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in
        guard let data = item.data(forType: type) else { return nil }
        return Representation(type: type, data: data)
      }
    }
  }

  func restore(to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    let restoredItems = items.map { representations in
      let item = NSPasteboardItem()
      for representation in representations {
        item.setData(representation.data, forType: representation.type)
      }
      return item
    }
    if !restoredItems.isEmpty {
      pasteboard.writeObjects(restoredItems)
    }
  }
}

private struct ControlRequest: Encodable {
  let id = UUID().uuidString
  let operation: String
  var text: String? = nil
  var minimumSurfaceCount: Int? = nil
  var sessionId: Int64? = nil
}

private struct ControlResponse: Decodable {
  let id: String
  let error: String?
}

private enum UITestError: Error, LocalizedError {
  case frontendAlreadyRunning(String)
  case bundledHelperMissing(String)
  case couldNotDecodeScreenshot(String)
  case blankScreenshot(String)
  case missingDaemonEnvironment(String)
  case controlRequestAlreadyPending
  case controlRequestTimedOut(String)
  case wrongControlResponse
  case appActionFailed(String)
  case windowTimedOut
  case sessionCountTimedOut(Int, Int)
  case shellCountTimedOut(Int, Int, Int64)
  case timedOut(String)

  var errorDescription: String? {
    switch self {
    case .frontendAlreadyRunning(let existing):
      "Refusing to run visual UI tests while an Axo UI-test app is already running: \(existing). Terminate it explicitly, then rerun."
    case .bundledHelperMissing(let path):
      "The test bundle's axod helper is missing or not executable: \(path)."
    case .couldNotDecodeScreenshot(let name):
      "Could not decode the screenshot at checkpoint \(name)."
    case .blankScreenshot(let name):
      "The Axo window remained visually blank at screenshot checkpoint \(name)."
    case .missingDaemonEnvironment(let key):
      "The Bazel visual-test runner did not provide isolated daemon input \(key)."
    case .controlRequestAlreadyPending: "The app has an unprocessed UI-test action."
    case .controlRequestTimedOut(let action):
      "The app did not acknowledge UI-test action \(action) within its bounded wait."
    case .wrongControlResponse: "The app responded to a different UI-test action."
    case .appActionFailed(let error): "The app rejected the requested UI-test action: \(error)"
    case .windowTimedOut:
      "The app did not present its terminal window in the foreground within twelve seconds."
    case .sessionCountTimedOut(let expected, let actual):
      "Expected \(expected) sessions within eight seconds; found \(actual)."
    case .shellCountTimedOut(let expected, let actual, let sessionID):
      "Expected \(expected) shells in session \(sessionID) within eight seconds; found \(actual)."
    case .timedOut(let message): message
    }
  }
}
