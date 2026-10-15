import AppKit
import AxoRPC
import CoreGraphics
import Foundation
import Vision
import XCTest

@testable import AxoMac

@MainActor
final class AxoVisualUITests: XCTestCase {
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
    let window = app.windows.firstMatch
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
    try fixture.assertContainsText("AXO VISUAL RIGHT 2846", in: afterExit)
    try fixture.assertDoesNotContainText("AXO VISUAL INITIAL 7319", in: afterExit)

    window.typeText("printf 'AXO VISUAL SURVIVOR 5690\\n'\n")
    try await Task.sleep(for: .milliseconds(500))
    let survivorOutput = try fixture.capture("12-surviving-shell-output", in: window)
    try fixture.assertContainsText("AXO VISUAL SURVIVOR 5690", in: survivorOutput)

    window.typeKey("t", modifierFlags: .command)
    try await waitForSessionCount(2, model: model)
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
    try await Task.sleep(for: .milliseconds(500))
    let reopenedWindow = app.windows.firstMatch
    let restoredTUI = try fixture.capture("17-restored-tui-after-relaunch", in: reopenedWindow)
    try fixture.assertContainsText("AXO REATTACHED TUI 8751", in: restoredTUI)

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
    XCTAssertTrue(settingsWindow.staticTexts["Axo D version"].exists)
    XCTAssertTrue(settingsWindow.staticTexts["Axo D build"].exists)
    XCTAssertTrue(settingsWindow.staticTexts["Daemon status"].exists)
    try fixture.capture("18-about-settings", in: settingsWindow)
    XCTAssertEqual(fixture.screenshotsWritten, 20)
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

  func waitForWindow() async throws {
    guard app.wait(for: .runningForeground, timeout: 12),
      app.windows.firstMatch.waitForExistence(timeout: 8)
    else { throw UITestError.windowTimedOut }
  }

  func waitForTerminalReady() async throws {
    try await perform(ControlRequest(operation: "wait-ready"))
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
  var minimumSurfaceCount: Int?
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
    }
  }
}
