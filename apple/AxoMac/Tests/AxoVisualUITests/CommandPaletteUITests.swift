import AppKit
import AxoProtocol
import AxoRPC
import Foundation
import XCTest

@testable import AxoMac

/// The command palette over live Ghostty surfaces: ⇧⌘P works while a terminal has focus, the
/// query field gets the keyboard, choosing runs the command, and closing hands typing back to
/// the terminal. Keystrokes are real key events, not the control socket.
extension AxoVisualUITests {
  func testCommandPaletteRunsCommandsAndReturnsTypingToTheTerminal() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    fixture.launchApp()

    let model = TerminalSessionsModel(socketPath: try UnixSocketPath(fixture.socketURL.path))
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()
    try await waitForSessionCount(1, model: model)
    let sessionID = try XCTUnwrap(model.sessions.first?.id)
    let window = fixture.terminalWindow
    let query = app.textFields["command-palette-query"]

    // Opened from a focused terminal; typing goes to the query (typeText fails without focus).
    window.typeKey("p", modifierFlags: [.command, .shift])
    XCTAssertTrue(query.waitForExistence(timeout: 3), "⇧⌘P must reach Axo over a terminal")
    query.typeText("split ri")
    XCTAssertTrue(
      app.descendants(matching: .any)["command-palette-row-command:Split Right"].exists)
    query.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    try await waitForShellCount(2, sessionID: sessionID, model: model)
    XCTAssertTrue(query.waitForNonExistence(timeout: 3))
    try fixture.capture("palette-01-split-right", in: window)

    // Escape closes without acting, and typing goes back to the terminal.
    window.typeKey("p", modifierFlags: [.command, .shift])
    XCTAssertTrue(query.waitForExistence(timeout: 3))
    query.typeText("close focused")
    query.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(query.waitForNonExistence(timeout: 3))
    window.typeText("echo palette-$((40+2))\r")
    try await Task.sleep(for: .milliseconds(500))
    try fixture.assertContainsText("palette-42", in: fixture.capture("palette-02-typing-returns", in: window))
    await model.refresh()
    XCTAssertEqual(model.session(for: sessionID)?.shells.count, 2, "Escape must not run the command")

    // ⇧⌘P again closes an open palette.
    window.typeKey("p", modifierFlags: [.command, .shift])
    XCTAssertTrue(query.waitForExistence(timeout: 3))
    window.typeKey("p", modifierFlags: [.command, .shift])
    XCTAssertTrue(query.waitForNonExistence(timeout: 3))
  }
}
