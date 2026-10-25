import AppKit
import AxoProtocol
import CoreGraphics
import Foundation
import Vision
import XCTest

@testable import AxoMac


@MainActor
final class UITestFixture {
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

    let goToFolder = app.sheets["GoToWindow"]
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

  func selectSession(_ sessionId: SessionID) async throws {
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

struct PasteboardSnapshot {
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

struct ControlRequest: Encodable {
  let id = UUID().uuidString
  let operation: String
  var text: String? = nil
  var minimumSurfaceCount: Int? = nil
  var sessionId: SessionID? = nil
}

struct ControlResponse: Decodable {
  let id: String
  let error: String?
}

enum UITestError: Error, LocalizedError {
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
  case shellCountTimedOut(Int, Int, SessionID)
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
