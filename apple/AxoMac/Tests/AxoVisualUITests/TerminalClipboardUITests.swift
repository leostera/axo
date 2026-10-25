import AppKit
import AxoProtocol
import CoreGraphics
import Foundation
import Vision
import XCTest

@testable import AxoMac


/// Clipboard consent for terminal reads and writes.
extension AxoVisualUITests {
  func testClipboardReadsRequireApprovalAndRejectDenialOrCancellation() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let pasteboardSnapshot = PasteboardSnapshot()
    defer { pasteboardSnapshot.restore() }
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }

    let responseURL = fixture.root.appendingPathComponent("clipboard-read-response")
    let scriptURL = fixture.root.appendingPathComponent("clipboard-read-probe.py")
    let script = #"""
      import os, select, sys, termios, time, tty
      response_path = \#(try pythonStringLiteral(responseURL.path))
      fd = sys.stdin.fileno()
      previous_terminal = termios.tcgetattr(fd)
      tty.setraw(fd)
      try:
          os.write(sys.stdout.fileno(), b"\x1b]52;c;?\x07")
          deadline = time.monotonic() + 10
          data = bytearray()
          while time.monotonic() < deadline and not data.endswith(b"\x1b\\"):
              readable, _, _ = select.select([fd], [], [], 0.05)
              if readable:
                  data.extend(os.read(fd, 1))
          if not data.endswith(b"\x1b\\"):
              raise TimeoutError("clipboard query did not receive an OSC 52 response")
          with open(response_path, "wb") as response:
              response.write(data)
      finally:
          termios.tcsetattr(fd, termios.TCSANOW, previous_terminal)
      """#
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()

    func queryClipboard() async throws -> Data {
      try? FileManager.default.removeItem(at: responseURL)
      try await fixture.typeText("python3 '\(scriptURL.path)'\n")
      return try await waitForFile(at: responseURL, timeout: 12)
    }

    func respond(_ button: String? = nil) throws {
      let alert = app.alerts.firstMatch
      XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
      if let button {
        alert.buttons[button].click()
      } else {
        alert.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
      }
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("NEVER_DISCLOSE_ON_DENY", forType: .string)
    let deniedTask = Task { try await queryClipboard() }
    try respond("Don't Allow")
    let deniedResponse = try await deniedTask.value
    XCTAssertEqual(
      Array(deniedResponse), Array([0x1b] + Array("]52;c;".utf8) + [0x1b, 0x5c]))
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "NEVER_DISCLOSE_ON_DENY")

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("APPROVED_CLIPBOARD_TEXT", forType: .string)
    let approvedTask = Task { try await queryClipboard() }
    try respond("Allow")
    let approvedResponse = try await approvedTask.value
    let encoded = String(decoding: approvedResponse.dropFirst(7).dropLast(2), as: UTF8.self)
    XCTAssertEqual(Data(base64Encoded: encoded), Data("APPROVED_CLIPBOARD_TEXT".utf8))

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("NEVER_DISCLOSE_ON_CANCEL", forType: .string)
    let cancelledTask = Task { try await queryClipboard() }
    try respond()
    let cancelledResponse = try await cancelledTask.value
    XCTAssertEqual(
      Array(cancelledResponse), Array([0x1b] + Array("]52;c;".utf8) + [0x1b, 0x5c]))
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "NEVER_DISCLOSE_ON_CANCEL")
  }

  func testClipboardWritesRequireApprovalAndRejectDenialOrCancellation() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let pasteboardSnapshot = PasteboardSnapshot()
    let selectionPasteboard = NSPasteboard(name: .init(TerminalClipboardPolicy.selectionPasteboardName))
    let selectionSnapshot = PasteboardSnapshot(pasteboard: selectionPasteboard)
    defer {
      pasteboardSnapshot.restore()
      selectionSnapshot.restore(to: selectionPasteboard)
    }
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    let scriptURL = fixture.root.appendingPathComponent("clipboard-write-probe.py")
    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()

    func triggerWrite(_ text: String, clipboard: String = "c") async throws {
      let encoded = Data(text.utf8).base64EncodedString()
      let script = """
        import sys
        sys.stdout.write(chr(27) + "]52;\(clipboard);\(encoded)" + chr(7))
        sys.stdout.flush()
        """
      try script.write(to: scriptURL, atomically: true, encoding: .utf8)
      try await fixture.typeText("python3 '\(scriptURL.path)'\n")
    }

    func respond(_ button: String? = nil) {
      let alert = app.alerts.firstMatch
      XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
      if let button {
        alert.buttons[button].click()
      } else {
        alert.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
      }
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("PRESERVED_BEFORE_DENIAL", forType: .string)
    try await triggerWrite("DENIED_TERMINAL_WRITE")
    respond("Don't Allow")
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "PRESERVED_BEFORE_DENIAL")

    try await triggerWrite("APPROVED_TERMINAL_WRITE")
    respond("Allow")
    let approvedDeadline = Date().addingTimeInterval(3)
    while Date() < approvedDeadline
      && NSPasteboard.general.string(forType: .string) != "APPROVED_TERMINAL_WRITE"
    {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "APPROVED_TERMINAL_WRITE")

    selectionPasteboard.clearContents()
    try await triggerWrite("SELECTION_TERMINAL_WRITE", clipboard: "s")
    respond("Allow")
    let selectionDeadline = Date().addingTimeInterval(3)
    while Date() < selectionDeadline
      && selectionPasteboard.string(forType: .string) != "SELECTION_TERMINAL_WRITE"
    {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(selectionPasteboard.string(forType: .string), "SELECTION_TERMINAL_WRITE")

    try await triggerWrite("CANCELLED_TERMINAL_WRITE")
    respond()
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "APPROVED_TERMINAL_WRITE")
  }
}
