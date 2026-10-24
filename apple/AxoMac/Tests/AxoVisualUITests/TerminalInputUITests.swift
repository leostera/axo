import AppKit
import AxoRPC
import CoreGraphics
import Foundation
import Vision
import XCTest

@testable import AxoMac


/// Keyboard, mouse, scroll and accessibility behavior of terminal surfaces.
extension AxoVisualUITests {
  func testKittyKeyboardNegotiationEncodesReturnAndShiftEnter() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }

    let readyURL = fixture.root.appendingPathComponent("kitty-keyboard-ready")
    let enterURL = fixture.root.appendingPathComponent("kitty-keyboard-enter")
    let shiftEnterURL = fixture.root.appendingPathComponent("kitty-keyboard-shift-enter")
    let commandKeyURL = fixture.root.appendingPathComponent("kitty-keyboard-command-key")
    let ghosttyBindingURL = fixture.root.appendingPathComponent("ghostty-binding-output")
    let scriptURL = fixture.root.appendingPathComponent("kitty-keyboard-probe.py")
    let ghosttyConfigDirectory = fixture.root.appendingPathComponent("home/.config/ghostty")
    try FileManager.default.createDirectory(
      at: ghosttyConfigDirectory, withIntermediateDirectories: true)
    try "keybind = super+shift+f=text:AXO_GHOSTTY_BINDING\n".write(
      to: ghosttyConfigDirectory.appendingPathComponent("config"),
      atomically: true,
      encoding: .utf8
    )
    let script = #"""
      import os, select, sys, termios, time, tty

      ready_path = \#(try pythonStringLiteral(readyURL.path))
      enter_path = \#(try pythonStringLiteral(enterURL.path))
      shift_enter_path = \#(try pythonStringLiteral(shiftEnterURL.path))
      command_key_path = \#(try pythonStringLiteral(commandKeyURL.path))
      ghostty_binding_path = \#(try pythonStringLiteral(ghosttyBindingURL.path))
      fd = sys.stdin.fileno()
      previous_terminal = termios.tcgetattr(fd)

      def read_exact(size, timeout):
          deadline = time.monotonic() + timeout
          data = bytearray()
          while len(data) < size and time.monotonic() < deadline:
              readable, _, _ = select.select([fd], [], [], 0.05)
              if readable:
                  data.extend(os.read(fd, size - len(data)))
          if len(data) != size:
              raise TimeoutError("timed out waiting for a configured Ghostty binding")
          return bytes(data)

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
          with open(ghostty_binding_path, "wb") as binding:
              binding.write(read_exact(len(b"AXO_GHOSTTY_BINDING"), 10))
          with open(enter_path, "wb") as enter:
              enter.write(read_one_key(10))
          with open(shift_enter_path, "wb") as shift_enter:
              shift_enter.write(read_one_key(10))
          with open(command_key_path, "wb") as command_key:
              command_key.write(read_one_key(10))
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
    fixture.terminalWindow.typeKey("f", modifierFlags: [.command, .shift])
    _ = try await waitForFile(at: ghosttyBindingURL, timeout: 5)
    XCTAssertEqual(try Data(contentsOf: ghosttyBindingURL), Data("AXO_GHOSTTY_BINDING".utf8))

    fixture.terminalWindow.click()
    fixture.terminalWindow.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    _ = try await waitForFile(at: enterURL, timeout: 5)
    fixture.terminalWindow.typeKey(XCUIKeyboardKey.return, modifierFlags: .shift)
    _ = try await waitForFile(at: shiftEnterURL, timeout: 5)

    XCTAssertEqual(try Data(contentsOf: enterURL), Data([0x0d]))
    let shiftEnter = try Data(contentsOf: shiftEnterURL)
    let shiftEnterHex = shiftEnter.map { String(format: "%02x", $0) }.joined(separator: " ")
    XCTAssertEqual(shiftEnterHex, "1b 5b 31 33 3b 32 75")

    fixture.terminalWindow.typeKey("j", modifierFlags: .command)
    _ = try await waitForFile(at: commandKeyURL, timeout: 5)
    XCTAssertEqual(
      try Data(contentsOf: commandKeyURL),
      Data([0x1b, 0x5b, 0x31, 0x30, 0x36, 0x3b, 0x39, 0x75])
    )
  }

  func testFocusOnlyClickIsNotReportedToTerminalMouseMode() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    let readyURL = fixture.root.appendingPathComponent("mouse-reporting-ready")
    let reportURL = fixture.root.appendingPathComponent("mouse-reporting-event")
    let scriptURL = fixture.root.appendingPathComponent("mouse-reporting-probe.py")
    let script = #"""
      import os, select, sys, termios, time, tty
      ready_path = \#(try pythonStringLiteral(readyURL.path))
      report_path = \#(try pythonStringLiteral(reportURL.path))
      fd = sys.stdin.fileno()
      previous_terminal = termios.tcgetattr(fd)
      tty.setraw(fd)
      try:
          sys.stdout.write(chr(27) + "[?1000h")
          sys.stdout.flush()
          open(ready_path, "wb").close()
          deadline = time.monotonic() + 10
          data = bytearray()
          report_prefix = bytes([27, 91, 77])
          while time.monotonic() < deadline:
              readable, _, _ = select.select([fd], [], [], 0.05)
              if readable:
                  data.extend(os.read(fd, 1))
                  if report_prefix in data and len(data) >= data.index(report_prefix) + 6:
                      with open(report_path, "wb") as report:
                          report.write(data)
                      break
      finally:
          sys.stdout.write(chr(27) + "[?1000l")
          sys.stdout.flush()
          termios.tcsetattr(fd, termios.TCSANOW, previous_terminal)
      """#
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()
    let model = TerminalSessionsModel(
      socketPath: try UnixSocketPath(fixture.socketURL.path), helperURL: fixture.helperURL)
    try await waitForSessionCount(1, model: model)
    let sessionID = try XCTUnwrap(model.sessions.first?.id)
    fixture.terminalWindow.typeKey("d", modifierFlags: .command)
    try await waitForShellCount(2, sessionID: sessionID, model: model)
    try await fixture.waitForSurfaceCount(2)
    try await fixture.typeText("python3 '\(scriptURL.path)'\n")
    _ = try await waitForFile(at: readyURL, timeout: 5)

    fixture.terminalWindow.typeKey("[", modifierFlags: .command)
    let rightPane = fixture.terminalWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
    rightPane.click()
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
    rightPane.click()
    _ = try await waitForFile(at: reportURL, timeout: 5)
    XCTAssertTrue(String(decoding: try Data(contentsOf: reportURL), as: UTF8.self).contains("M"))
  }

  func testTerminalScrollWheelReachesMouseReportingChild() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    let readyURL = fixture.root.appendingPathComponent("scroll-reporting-ready")
    let reportURL = fixture.root.appendingPathComponent("scroll-reporting-event")
    let scriptURL = fixture.root.appendingPathComponent("scroll-reporting-probe.py")
    let script = #"""
      import os, select, sys, termios, time, tty
      ready_path = \#(try pythonStringLiteral(readyURL.path))
      report_path = \#(try pythonStringLiteral(reportURL.path))
      fd = sys.stdin.fileno()
      previous_terminal = termios.tcgetattr(fd)
      tty.setraw(fd)
      try:
          sys.stdout.write(chr(27) + "[?1000h")
          sys.stdout.flush()
          open(ready_path, "wb").close()
          deadline = time.monotonic() + 10
          data = bytearray()
          report_prefix = bytes([27, 91, 77])
          while time.monotonic() < deadline:
              readable, _, _ = select.select([fd], [], [], 0.05)
              if readable:
                  data.extend(os.read(fd, 1))
                  if report_prefix in data and len(data) >= data.index(report_prefix) + 6:
                      with open(report_path, "wb") as report:
                          report.write(data)
                      break
      finally:
          sys.stdout.write(chr(27) + "[?1000l")
          sys.stdout.flush()
          termios.tcsetattr(fd, termios.TCSANOW, previous_terminal)
      """#
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()
    try await fixture.typeText("python3 '\(scriptURL.path)'\n")
    _ = try await waitForFile(at: readyURL, timeout: 5)
    try await Task.sleep(for: .milliseconds(300))

    let terminal = fixture.terminalWindow.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    terminal.scroll(byDeltaX: 0, deltaY: 64)
    _ = try await waitForFile(at: reportURL, timeout: 5)
    let report = try Data(contentsOf: reportURL)
    XCTAssertGreaterThanOrEqual(report.count, 6)
    XCTAssertEqual(Array(report.prefix(3)), [0x1b, 0x5b, 0x4d])
    XCTAssertTrue([96, 97].contains(Int(report[3])), "Expected a wheel-up or wheel-down report")
  }
  func testTerminalAccessibilityExposesVisibleScreenText() async throws {
    try assertNoAxoUITestAppIsAlreadyRunning()
    let app = XCUIApplication(bundleIdentifier: "dev.leostera.axo.ui-tests")
    let fixture = try UITestFixture(app: app)
    defer { fixture.stop() }
    fixture.launchApp()
    try await fixture.waitForWindow()
    try await fixture.waitForTerminalReady()
    let window = fixture.terminalWindow
    window.click()
    window.typeText("printf 'AXO_ACCESSIBILITY_BACKLOG_5207\\n'; seq 1 80; printf 'AXO_ACCESSIBILITY_VISIBLE_5207\\n'\n")

    let terminal = app.descendants(matching: .any)
      .matching(identifier: "axo-terminal-surface").firstMatch
    XCTAssertTrue(terminal.waitForExistence(timeout: 5))
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let value = terminal.value as? String ?? ""
      if value.contains("AXO_ACCESSIBILITY_VISIBLE_5207") { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let value = terminal.value as? String ?? ""
    XCTAssertTrue(value.contains("AXO_ACCESSIBILITY_VISIBLE_5207"))
    XCTAssertFalse(value.contains("AXO_ACCESSIBILITY_BACKLOG_5207"))
  }
}
