import Darwin
import Foundation
import XCTest

final class TerminalAppE2ETests: XCTestCase {
  func testBundledAppSelfTestAttachesToDaemonOwnedPTY() throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("axo-app-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let archive = try runfile(named: "AXO_APP_BUNDLE_ZIP")
    try extractApp(at: archive, into: root)

    let appURL = root.appendingPathComponent("Axo.app", isDirectory: true)
    let appExecutable = appURL.appendingPathComponent("Contents/MacOS/Axo")
    let attachHelper = appURL.appendingPathComponent("Contents/Helpers/axod")
    let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: appExecutable.path))
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: attachHelper.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: resources.appendingPathComponent(
          "ghostty-resources/shell-integration/zsh/ghostty-integration"
        ).path
      )
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: resources.appendingPathComponent("terminfo/78/xterm-ghostty").path
      )
    )

    let socketPath = root.appendingPathComponent("axod.sock").path
    let serverDirectory = root.appendingPathComponent("server", isDirectory: true)
    let daemon = Process()
    daemon.executableURL = attachHelper
    daemon.arguments = [
      "--socket", socketPath,
      "--server-dir", serverDirectory.path,
    ]
    // The Home Workspace's Session starts Pi at once: use the fixture, never the user's Pi.
    daemon.environment = ProcessInfo.processInfo.environment.merging([
      "AXO_PI_EXECUTABLE": try runfile(named: "AXO_TEST_PI_EXECUTABLE").absoluteURL.path,
      "AXO_PI_EXTENSION_PATH": try runfile(named: "AXO_PI_EXTENSION_PATH").absoluteURL.path,
    ]) { _, newValue in newValue }
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = FileHandle.nullDevice
    try daemon.run()
    defer { stop(daemon) }
    try waitForSocket(at: socketPath, daemon: daemon)

    let app = Process()
    app.executableURL = appExecutable
    app.arguments = ["--self-test"]
    app.environment = ProcessInfo.processInfo.environment.merging([
      "AXO_SELF_TEST_SOCKET": socketPath,
      "AXO_SELF_TEST_AXOD": attachHelper.path,
    ]) { _, newValue in newValue }
    let standardOutput = Pipe()
    let standardError = Pipe()
    app.standardOutput = standardOutput
    app.standardError = standardError
    try app.run()

    let exited = waitForExit(app, timeout: 15)
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    let message = String(decoding: output + errorOutput, as: UTF8.self)
    XCTAssertTrue(exited, "Axo --self-test timed out. Output: \(message)")
    XCTAssertEqual(app.terminationStatus, 0, "Axo --self-test failed: \(message)")
    XCTAssertTrue(message.contains("AXO_SELF_TEST_OK"), "Missing success marker: \(message)")
  }

  private func extractApp(at archive: URL, into directory: URL) throws {
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", archive.path, directory.path]
    ditto.standardOutput = FileHandle.nullDevice
    ditto.standardError = FileHandle.nullDevice
    try ditto.run()
    XCTAssertTrue(waitForExit(ditto, timeout: 10), "ditto did not extract the Axo app archive")
    XCTAssertEqual(ditto.terminationStatus, 0, "ditto failed to extract the Axo app archive")
  }

  private func runfile(named variable: String) throws -> URL {
    guard let relativePath = ProcessInfo.processInfo.environment[variable] else {
      throw TerminalAppE2EError.missingRunfile(variable)
    }

    let fileManager = FileManager.default
    var candidates = [URL(fileURLWithPath: relativePath)]
    if let runfilesPath = ProcessInfo.processInfo.environment["RUNFILES_DIR"]
      ?? ProcessInfo.processInfo.environment["TEST_SRCDIR"]
    {
      let runfiles = URL(fileURLWithPath: runfilesPath, isDirectory: true)
      candidates.append(runfiles.appendingPathComponent(relativePath))
      if let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] {
        candidates.append(
          runfiles.appendingPathComponent(workspace).appendingPathComponent(relativePath))
      }
      candidates.append(
        runfiles.appendingPathComponent("_main").appendingPathComponent(relativePath))
    }

    guard let file = candidates.first(where: { fileManager.isReadableFile(atPath: $0.path) }) else {
      throw TerminalAppE2EError.runfileNotFound(relativePath)
    }
    return file
  }

  private func waitForSocket(at path: String, daemon: Process) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: path) { return }
      guard daemon.isRunning else { throw TerminalAppE2EError.daemonExitedEarly }
      Thread.sleep(forTimeInterval: 0.02)
    }
    throw TerminalAppE2EError.daemonTimedOut
  }

  @discardableResult
  private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard process.isRunning else { return true }

    stop(process)
    return false
  }

  private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let gracefulDeadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < gracefulDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard process.isRunning else { return }

    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    let killDeadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < killDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
  }
}

private enum TerminalAppE2EError: Error, LocalizedError {
  case missingRunfile(String)
  case runfileNotFound(String)
  case daemonExitedEarly
  case daemonTimedOut

  var errorDescription: String? {
    switch self {
    case .missingRunfile(let variable):
      "Bazel did not configure the runfile path in \(variable)."
    case .runfileNotFound(let path):
      "Could not find the Bazel runfile \(path)."
    case .daemonExitedEarly:
      "The test daemon exited before creating its socket."
    case .daemonTimedOut:
      "The test daemon did not create its socket within five seconds."
    }
  }
}
