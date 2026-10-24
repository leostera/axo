import AxoRPC
import Darwin
import Foundation
import XCTest

@testable import AxoMac

@MainActor
final class TerminalWorkbenchE2ETests: XCTestCase {
  func testExitingOneNestedShellKeepsSiblingShellsAndLayoutUsable() async throws {
    try await withWorkbench { model, daemon in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)

      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first { $0.id != firstShell.id })
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != firstShell.id && $0.id != secondShell.id
        }
      )

      try daemon.sendExit(to: secondShell)
      try await waitUntilShellIsGone(secondShell.id, from: model)

      XCTAssertEqual(model.selectedSessionID, sessionID)
      XCTAssertEqual(model.focusedShellID, thirdShell.id)
      XCTAssertEqual(model.layout?.shellIDs, [firstShell.id, thirdShell.id])
      try daemon.assertCanRunCommand(in: firstShell)
      try daemon.assertCanRunCommand(in: thirdShell)
    }
  }

  func testRefreshFocusesTheNewestCreatedPane() async throws {
    try await withWorkbench { model, daemon in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)
      let socketPath = try UnixSocketPath(daemon.socketPath.path)

      let newestShell = try await UnixSocketRPC.createShell(in: sessionID, at: socketPath)
      await model.refresh()

      XCTAssertEqual(model.focusedShellID, newestShell.id)
      XCTAssertEqual(model.layout?.shellIDs, [firstShell.id, newestShell.id])
    }
  }

  func testPaneHierarchySurvivesWorkbenchModelRecreation() async throws {
    let daemon = try DaemonFixture()
    defer { daemon.stop() }
    let socketPath = try UnixSocketPath(daemon.socketPath.path)
    let defaultsSuite = "axo-terminal-layout-test-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let firstModel = TerminalSessionsModel(
      socketPath: socketPath,
      helperURL: daemon.executableURL,
      selectedSessionDefaults: defaults
    )
    await firstModel.refresh()
    await firstModel.createSession()
    let sessionID = try XCTUnwrap(firstModel.selectedSessionID)
    let firstShell = try XCTUnwrap(firstModel.session(for: sessionID)?.shells.first)

    await firstModel.split(.right)
    await firstModel.split(.down)
    if case .split(let splitID, _, _, _, _) = firstModel.layout {
      firstModel.resizeSplit(splitID, to: 0.63)
    }
    let expectedLayout = try XCTUnwrap(firstModel.layout)
    XCTAssertEqual(expectedLayout.orderedShellIDs.count, 3)
    try await waitUntilLayout(expectedLayout, for: sessionID, at: socketPath)

    let reopenedModel = TerminalSessionsModel(
      socketPath: socketPath,
      helperURL: daemon.executableURL,
      selectedSessionDefaults: defaults
    )
    await reopenedModel.refresh()

    XCTAssertEqual(reopenedModel.selectedSessionID, sessionID)
    XCTAssertEqual(reopenedModel.layout, expectedLayout)
    XCTAssertEqual(reopenedModel.layout?.firstShellID, firstShell.id)
  }

  func testClosingNewWorkspaceSessionReturnsToPreviousSessionInWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-session-focus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await withWorkbench { model, _ in
      await model.createWorkspace(
        name: "Session Focus",
        directoryPath: directory.path,
        directoryBookmark: nil
      )
      XCTAssertNil(model.workspaceCreationError)

      let previousSessionID = try XCTUnwrap(model.selectedSessionID)
      let workspaceID = try XCTUnwrap(model.session(for: previousSessionID)?.workspaceId)
      await model.createSessionInCurrentContext()

      let newSessionID = try XCTUnwrap(model.selectedSessionID)
      XCTAssertNotEqual(newSessionID, previousSessionID)
      XCTAssertEqual(model.session(for: newSessionID)?.workspaceId, workspaceID)
      let shell = try XCTUnwrap(model.session(for: newSessionID)?.shells.first)

      await model.closeShell(shell.id)

      XCTAssertEqual(model.selectedSessionID, previousSessionID)
      XCTAssertEqual(model.session(for: previousSessionID)?.workspaceId, workspaceID)
      XCTAssertNil(model.errorMessage)
    }
  }

  func testPaneNavigationCyclesInLayoutOrder() async throws {
    try await withWorkbench { model, _ in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)

      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first { $0.id != firstShell.id }
      )
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != firstShell.id && $0.id != secondShell.id
        }
      )
      XCTAssertEqual(model.layout?.orderedShellIDs, [firstShell.id, secondShell.id, thirdShell.id])

      model.focusPreviousPane()
      XCTAssertEqual(model.focusedShellID, secondShell.id)
      model.focusPreviousPane()
      XCTAssertEqual(model.focusedShellID, firstShell.id)
      model.focusPreviousPane()
      XCTAssertEqual(model.focusedShellID, thirdShell.id)
      model.focusNextPane()
      XCTAssertEqual(model.focusedShellID, firstShell.id)
    }
  }

  func testSessionNavigationCyclesInSessionOrder() async throws {
    try await withWorkbench { model, daemon in
      let firstSessionID = try XCTUnwrap(model.selectedSessionID)
      await model.createSession()
      let secondSessionID = try XCTUnwrap(model.selectedSessionID)
      XCTAssertNotEqual(firstSessionID, secondSessionID)
      let secondSession = try XCTUnwrap(model.session(for: secondSessionID))
      XCTAssertNil(secondSession.workspaceId)
      XCTAssertEqual(secondSession.initialPwd, daemon.homeDirectory.path)

      model.showNextSession()
      XCTAssertEqual(model.selectedSessionID, firstSessionID)
      model.showNextSession()
      XCTAssertEqual(model.selectedSessionID, secondSessionID)
      model.showPreviousSession()
      XCTAssertEqual(model.selectedSessionID, firstSessionID)
      model.showPreviousSession()
      XCTAssertEqual(model.selectedSessionID, secondSessionID)
    }
  }

  func testSessionNavigationFollowsWorkspaceThenStandaloneSidebarOrder() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-sidebar-order-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await withWorkbench { model, _ in
      let firstStandaloneID = try XCTUnwrap(model.selectedSessionID)
      await model.createWorkspace(
        name: "Sidebar Order",
        directoryPath: directory.path,
        directoryBookmark: nil
      )
      let firstWorkspaceSessionID = try XCTUnwrap(model.selectedSessionID)
      let workspaceID = try XCTUnwrap(model.session(for: firstWorkspaceSessionID)?.workspaceId)
      await model.createSession(in: workspaceID)
      let secondWorkspaceSessionID = try XCTUnwrap(model.selectedSessionID)
      await model.createSession()
      let secondStandaloneID = try XCTUnwrap(model.selectedSessionID)

      let sidebarOrder = [
        firstWorkspaceSessionID,
        secondWorkspaceSessionID,
        firstStandaloneID,
        secondStandaloneID,
      ]
      XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), sidebarOrder)

      model.showNextSession()
      XCTAssertEqual(model.selectedSessionID, firstWorkspaceSessionID)
      model.showNextSession()
      XCTAssertEqual(model.selectedSessionID, secondWorkspaceSessionID)
      model.showPreviousSession()
      XCTAssertEqual(model.selectedSessionID, firstWorkspaceSessionID)
      model.showPreviousSession()
      XCTAssertEqual(model.selectedSessionID, secondStandaloneID)
    }
  }

  func testClosingLastWorkspaceSessionRequiresConfirmationToArchiveWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-last-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await withWorkbench { model, _ in
      await model.createWorkspace(
        name: "Last Session",
        directoryPath: directory.path,
        directoryBookmark: nil
      )
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let workspaceID = try XCTUnwrap(model.session(for: sessionID)?.workspaceId)

      await model.requestCloseSession(sessionID)

      XCTAssertEqual(model.pendingWorkspaceArchiveConfirmation?.workspaceID, workspaceID)
      XCTAssertEqual(model.pendingWorkspaceArchiveConfirmation?.sessionID, sessionID)
      XCTAssertNotNil(model.session(for: sessionID))
      XCTAssertTrue(model.workspaces.contains { $0.workspaceId == workspaceID })

      let confirmation = try XCTUnwrap(model.pendingWorkspaceArchiveConfirmation)
      await model.confirmWorkspaceArchiveAndCloseSession(confirmation)

      XCTAssertNil(model.pendingWorkspaceArchiveConfirmation)
      XCTAssertNil(model.session(for: sessionID))
      XCTAssertFalse(model.workspaces.contains { $0.workspaceId == workspaceID })
      XCTAssertNil(model.errorMessage)
    }
  }

  func testCommandWClosureCollapsesNestedPaneWithoutKillingSiblings() async throws {
    try await withWorkbench { model, daemon in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)
      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first { $0.id != firstShell.id }
      )
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != firstShell.id && $0.id != secondShell.id
        }
      )
      XCTAssertEqual(model.focusedShellID, thirdShell.id)

      await model.closeShell(try XCTUnwrap(model.focusedShellID))

      XCTAssertEqual(model.layout?.shellIDs, [firstShell.id, secondShell.id])
      XCTAssertEqual(model.focusedShellID, secondShell.id)
      try daemon.assertCanRunCommand(in: firstShell)
      try daemon.assertCanRunCommand(in: secondShell)
    }
  }

  func testExitingTheOnlyShellSelectsTheDaemonReplacement() async throws {
    try await withWorkbench { model, daemon in
      let oldSessionID = try XCTUnwrap(model.selectedSessionID)
      let oldShell = try XCTUnwrap(model.session(for: oldSessionID)?.shells.first)

      try daemon.sendExit(to: oldShell)
      try await waitUntilSessionIsGone(oldSessionID, from: model)

      let replacementID = try XCTUnwrap(model.selectedSessionID)
      XCTAssertNotEqual(replacementID, oldSessionID)
      let replacementShell = try XCTUnwrap(model.session(for: replacementID)?.shells.first)
      XCTAssertEqual(model.layout, .pane(replacementShell.id))
      XCTAssertEqual(model.focusedShellID, replacementShell.id)
      try daemon.assertCanRunCommand(in: replacementShell)
    }
  }

  func testExitingUnselectedSessionPaneDoesNotResurrectItOnReturn() async throws {
    try await withWorkbench { model, daemon in
      let firstSessionID = try XCTUnwrap(model.selectedSessionID)
      let firstShell = try XCTUnwrap(model.session(for: firstSessionID)?.shells.first)
      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: firstSessionID)?.shells.first { $0.id != firstShell.id }
      )
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: firstSessionID)?.shells.first {
          $0.id != firstShell.id && $0.id != secondShell.id
        }
      )

      await model.createSession()
      let otherSessionID = try XCTUnwrap(model.selectedSessionID)
      XCTAssertNotEqual(otherSessionID, firstSessionID)

      try daemon.sendExit(to: secondShell)
      try await waitUntilShellIsGone(secondShell.id, from: model)
      XCTAssertEqual(model.selectedSessionID, otherSessionID)

      model.showSession(firstSessionID)
      XCTAssertEqual(model.layout?.shellIDs, [firstShell.id, thirdShell.id])
      XCTAssertFalse(model.layout?.contains(shellID: secondShell.id) ?? true)
      try daemon.assertCanRunCommand(in: firstShell)
      try daemon.assertCanRunCommand(in: thirdShell)
    }
  }

  func testExitingAllShellsInOneTabLeavesOtherTabIntact() async throws {
    try await withWorkbench { model, daemon in
      let originalSessionID = try XCTUnwrap(model.selectedSessionID)
      let originalShell = try XCTUnwrap(model.session(for: originalSessionID)?.shells.first)

      await model.createSession()
      let exitedSessionID = try XCTUnwrap(model.selectedSessionID)
      let firstExitedShell = try XCTUnwrap(model.session(for: exitedSessionID)?.shells.first)
      await model.split(.right)
      let lastExitedShell = try XCTUnwrap(
        model.session(for: exitedSessionID)?.shells.first { $0.id != firstExitedShell.id }
      )

      try daemon.sendExit(to: firstExitedShell)
      try await waitUntilShellIsGone(firstExitedShell.id, from: model)
      XCTAssertEqual(model.selectedSessionID, exitedSessionID)
      try daemon.sendExit(to: lastExitedShell)
      try await waitUntilSessionIsGone(exitedSessionID, from: model)

      XCTAssertEqual(model.selectedSessionID, originalSessionID)
      XCTAssertEqual(model.layout, .pane(originalShell.id))
      XCTAssertEqual(model.session(for: originalSessionID)?.shells, [originalShell])
      try daemon.assertCanRunCommand(in: originalShell)
    }
  }

  func testRepeatedNestedShellExitsCollapseOnlyTheirOwnBranches() async throws {
    try await withWorkbench { model, daemon in
      let sessionID = try XCTUnwrap(model.selectedSessionID)
      let initialShell = try XCTUnwrap(model.session(for: sessionID)?.shells.first)

      await model.split(.right)
      let secondShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first { $0.id != initialShell.id }
      )
      await model.split(.down)
      let thirdShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != initialShell.id && $0.id != secondShell.id
        }
      )
      await model.split(.right)
      let fourthShell = try XCTUnwrap(
        model.session(for: sessionID)?.shells.first {
          $0.id != initialShell.id && $0.id != secondShell.id && $0.id != thirdShell.id
        }
      )

      try daemon.sendExit(to: thirdShell)
      try await waitUntilShellIsGone(thirdShell.id, from: model)
      try daemon.sendExit(to: secondShell)
      try await waitUntilShellIsGone(secondShell.id, from: model)

      XCTAssertEqual(model.layout?.shellIDs, [initialShell.id, fourthShell.id])
      try daemon.assertCanRunCommand(in: initialShell)
      try daemon.assertCanRunCommand(in: fourthShell)
    }
  }

  private func waitUntilLayout(
    _ expected: TerminalLayout,
    for sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let sessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
      if let storedLayout = sessions.first(where: { $0.id == sessionID })?.layout,
        TerminalLayout(storedLayout) == expected
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("axod did not persist the session pane hierarchy")
  }

  private func withWorkbench(
    _ test: (TerminalSessionsModel, DaemonFixture) async throws -> Void
  ) async throws {
    let daemon = try DaemonFixture()
    defer { daemon.stop() }
    let socketPath = try UnixSocketPath(daemon.socketPath.path)
    let model = TerminalSessionsModel(socketPath: socketPath, helperURL: daemon.executableURL)
    await model.refresh()
    XCTAssertNil(model.errorMessage)
    if model.sessions.isEmpty { await model.createSession() }
    XCTAssertNotNil(model.selectedSessionID)

    try await test(model, daemon)
  }

  private func waitUntilShellIsGone(
    _ shellID: ShellID,
    from model: TerminalSessionsModel
  ) async throws {
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
      await model.refresh()
      if !model.sessions.flatMap(\.shells).contains(where: { $0.id == shellID }) {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Shell \(shellID) was not reaped within six seconds")
  }

  private func waitUntilSessionIsGone(
    _ sessionID: SessionID,
    from model: TerminalSessionsModel
  ) async throws {
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
      await model.refresh()
      if model.session(for: sessionID) == nil {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Session \(sessionID) was not reaped within six seconds")
  }
}

@MainActor
private final class DaemonFixture {
  let executableURL: URL
  let socketPath: URL
  /// The daemon's `HOME`; standalone Sessions start here.
  let homeDirectory: URL
  private let root: URL
  private let daemon: Process

  init() throws {
    executableURL = try Self.runfile(named: "AXOD_TEST_BINARY")
    root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent(
        "axo-wb-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
        isDirectory: true
      )
    socketPath = root.appendingPathComponent("axod.sock")
    let serverDirectory = root.appendingPathComponent("server", isDirectory: true)
    homeDirectory = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)

    daemon = Process()
    daemon.executableURL = executableURL
    daemon.arguments = ["--socket", socketPath.path, "--server-dir", serverDirectory.path]
    // Pi panes run the declared inert fixtures, never the developer's Pi or extension.
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = homeDirectory.path
    environment["AXO_PI_EXTENSION_PATH"] = try Self.runfile(
      named: "AXO_PI_EXTENSION_PATH", executable: false
    ).path
    environment["AXO_PI_EXECUTABLE"] = try Self.runfile(named: "AXO_TEST_PI_EXECUTABLE").path
    daemon.environment = environment
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = FileHandle.nullDevice
    try daemon.run()
    try waitForSocket()
  }

  func sendExit(to shell: TerminalShell) throws {
    let attachment = try attach(to: shell, output: FileHandle.nullDevice)
    try attachment.input.fileHandleForWriting.write(contentsOf: Data("exit\n".utf8))
  }

  func assertCanRunCommand(in shell: TerminalShell) throws {
    let output = Pipe()
    let attachment = try attach(to: shell, output: output)
    defer { stop(attachment.process) }

    let suffix = "SHELL_\(shell.id)_READY"
    let expectedMarker = Data("AXO_E2E_\(suffix)".utf8)
    let command = "printf 'AXO_E2E_' && printf '\(suffix)\\n'\n"
    try attachment.input.fileHandleForWriting.write(contentsOf: Data(command.utf8))

    let descriptor = output.fileHandleForReading.fileDescriptor
    let deadline = Date().addingTimeInterval(4)
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while Date() < deadline {
      var readyDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let timeout = Int32(max(1, deadline.timeIntervalSinceNow * 1_000))
      let ready = Darwin.poll(&readyDescriptor, 1, timeout)
      if ready == -1, errno == EINTR { continue }
      guard ready > 0 else { break }
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count == -1, errno == EINTR || errno == EAGAIN { continue }
      guard count > 0 else { break }
      received.append(contentsOf: buffer.prefix(count))
      if received.range(of: expectedMarker) != nil { return }
    }
    XCTFail(
      "Shell \(shell.id) did not execute a command after a sibling exited. PTY output: \(String(decoding: received, as: UTF8.self))"
    )
  }

  func stop() {
    stop(daemon)
    try? FileManager.default.removeItem(at: root)
  }

  private func attach(to shell: TerminalShell, output: Any) throws -> Attachment {
    let input = Pipe()
    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "terminal-attach",
      "--attach-socket", shell.attachSocketPath,
      "--shell-id", shell.id.description,
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    return Attachment(process: process, input: input)
  }

  private func waitForSocket() throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath.path) { return }
      guard daemon.isRunning else {
        let logPath = root.appendingPathComponent("server/stderr.log").path
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no server log>"
        throw E2EError.daemonExitedEarly(executableURL.path, daemon.terminationStatus, log)
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    throw E2EError.daemonTimedOut
  }

  private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let gracefulDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < gracefulDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard process.isRunning else { return }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    let killDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < killDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  private static func runfile(named variable: String, executable: Bool = true) throws -> URL {
    guard let relativePath = ProcessInfo.processInfo.environment[variable] else {
      throw E2EError.missingRunfile(variable)
    }
    let fileManager = FileManager.default
    var candidates = [URL(fileURLWithPath: relativePath)]
    if let root = ProcessInfo.processInfo.environment["RUNFILES_DIR"]
      ?? ProcessInfo.processInfo.environment["TEST_SRCDIR"]
    {
      let runfiles = URL(fileURLWithPath: root, isDirectory: true)
      candidates.append(runfiles.appendingPathComponent(relativePath))
      if let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] {
        candidates.append(
          runfiles.appendingPathComponent(workspace).appendingPathComponent(relativePath))
      }
      candidates.append(
        runfiles.appendingPathComponent("_main").appendingPathComponent(relativePath))
    }
    guard
      let file = candidates.first(where: {
        executable
          ? fileManager.isExecutableFile(atPath: $0.path)
          : fileManager.fileExists(atPath: $0.path)
      })
    else {
      throw E2EError.runfileNotFound(relativePath)
    }
    return file
  }
}

private struct Attachment {
  let process: Process
  let input: Pipe
}

private enum E2EError: Error, LocalizedError {
  case missingRunfile(String)
  case runfileNotFound(String)
  case daemonExitedEarly(String, Int32, String)
  case daemonTimedOut

  var errorDescription: String? {
    switch self {
    case .missingRunfile(let name): "Missing Bazel runfile environment variable \(name)."
    case .runfileNotFound(let path): "Could not find executable Bazel runfile \(path)."
    case .daemonExitedEarly(let path, let status, let log):
      "The isolated axod process at \(path) exited with status \(status) before creating its socket. Log: \(log)"
    case .daemonTimedOut: "The isolated axod process did not create its socket within five seconds."
    }
  }
}
