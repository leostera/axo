import AxoRPC
import Darwin
import Foundation

@testable import AxoMac

/// Exercises the bundled app-to-daemon contract without registering or changing a LaunchAgent.
@MainActor
enum AxoAppSelfTest {
  private static let successMarker = "AXO_APP_SELF_TEST_PTY_OK"

  static func run() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let socketValue = environment["AXO_SELF_TEST_SOCKET"] else {
      throw SelfTestError.missingTestSocket
    }
    let socketPath = try UnixSocketPath(socketValue)
    let helperURL =
      environment["AXO_SELF_TEST_AXOD"].map {
        URL(fileURLWithPath: $0)
      } ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")

    let health = try await UnixSocketRPC.health(at: socketPath)
    guard health.status == "running" else {
      throw SelfTestError.daemonUnavailable
    }

    let baselineSessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
    guard baselineSessions.count == 1 else {
      throw SelfTestError.unexpectedInitialSession
    }
    let session = try await UnixSocketRPC.createSession(at: socketPath)
    do {
      guard let firstShell = session.shells.first else {
        throw SelfTestError.createdShellMissing
      }
      try await verifyShells(
        [firstShell], in: session, at: socketPath, helperURL: helperURL)
      try await verifyUnchangedSessions(baselineSessions, at: socketPath)

      let secondShell = try await UnixSocketRPC.createShell(in: session.id, at: socketPath)
      let thirdShell = try await UnixSocketRPC.createShell(in: session.id, at: socketPath)
      try await verifyShells(
        [firstShell, secondShell, thirdShell],
        in: session,
        at: socketPath,
        helperURL: helperURL
      )
      try await verifyUnchangedSessions(baselineSessions, at: socketPath)

      let closedMiddleShell = try await UnixSocketRPC.closeShell(
        secondShell.id,
        in: session.id,
        at: socketPath
      )
      guard closedMiddleShell.archivedShellId == secondShell.id,
        closedMiddleShell.archivedSessionId == nil
      else {
        throw SelfTestError.splitShellCloseArchivedSession
      }
      try await verifyShells(
        [firstShell, thirdShell], in: session, at: socketPath, helperURL: helperURL)
      try await verifyUnchangedSessions(baselineSessions, at: socketPath)

      let closedFirstShell = try await UnixSocketRPC.closeShell(
        firstShell.id,
        in: session.id,
        at: socketPath
      )
      guard closedFirstShell.archivedShellId == firstShell.id,
        closedFirstShell.archivedSessionId == nil
      else {
        throw SelfTestError.nonLastShellCloseArchivedSession
      }

      for baselineSession in baselineSessions {
        let closedBaseline = try await UnixSocketRPC.closeSession(
          baselineSession.id,
          at: socketPath
        )
        guard closedBaseline.archivedSessionId == baselineSession.id,
          closedBaseline.replacement == nil
        else {
          throw SelfTestError.independentSessionCloseFailed
        }
      }

      let closedLastShell = try await UnixSocketRPC.closeShell(
        thirdShell.id,
        in: session.id,
        at: socketPath
      )
      guard closedLastShell.archivedShellId == thirdShell.id,
        closedLastShell.archivedSessionId == session.id,
        let replacement = closedLastShell.replacement,
        replacement.id != session.id
      else {
        throw SelfTestError.lastShellDidNotReplaceSession
      }
      let remainingSessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
      guard remainingSessions.contains(where: { $0.id == replacement.id }),
        !remainingSessions.contains(where: { $0.id == session.id })
      else {
        throw SelfTestError.replacementSessionMissing
      }
    } catch {
      _ = try? await UnixSocketRPC.closeSession(session.id, at: socketPath)
      throw error
    }
  }

  private static func verifyShells(
    _ shells: [TerminalShell],
    in session: TerminalSession,
    at socketPath: UnixSocketPath,
    helperURL: URL
  ) async throws {
    let sessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
    guard let listedSession = sessions.first(where: { $0.id == session.id }) else {
      throw SelfTestError.createdSessionMissing
    }
    guard Set(listedSession.shells.map(\.id)) == Set(shells.map(\.id)) else {
      throw SelfTestError.splitShellSetMismatch
    }
    for shell in shells {
      try verifyPTYAttachment(shell, helperURL: helperURL)
    }
  }

  private static func verifyUnchangedSessions(
    _ expectedSessions: [TerminalSession],
    at socketPath: UnixSocketPath
  ) async throws {
    let activeSessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
    guard expectedSessions.allSatisfy({ activeSessions.contains($0) }) else {
      throw SelfTestError.independentSessionChanged
    }
  }

  private static func verifyPTYAttachment(
    _ shell: TerminalShell,
    helperURL: URL
  ) throws {
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      throw SelfTestError.helperMissing(helperURL.path)
    }

    let helper = Process()
    let input = Pipe()
    let output = Pipe()
    helper.executableURL = helperURL
    helper.arguments = [
      "terminal-attach",
      "--attach-socket", shell.attachSocketPath,
      "--shell-id", shell.id.description,
    ]
    helper.standardInput = input
    helper.standardOutput = output
    helper.standardError = FileHandle.nullDevice
    try helper.run()
    defer { stop(helper) }

    let markerText = "\(successMarker)_SHELL_\(shell.id)"
    let command =
      "test -f \"$TERMINFO/78/xterm-ghostty\" && test -f \"$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration\" && printf '\(successMarker)' && printf '_SHELL_\(shell.id)\\n'\n"
    try input.fileHandleForWriting.write(contentsOf: Data(command.utf8))

    let outputDescriptor = output.fileHandleForReading.fileDescriptor
    let deadline = Date().addingTimeInterval(5)
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let marker = Data(markerText.utf8)

    while Date() < deadline {
      var descriptor = pollfd(
        fd: outputDescriptor,
        events: Int16(POLLIN),
        revents: 0
      )
      let milliseconds = Int32(max(1, deadline.timeIntervalSinceNow * 1_000))
      let ready = Darwin.poll(&descriptor, 1, milliseconds)
      if ready == -1 {
        if errno == EINTR { continue }
        throw SelfTestError.outputReadFailed(String(cString: strerror(errno)))
      }
      guard ready > 0 else { continue }

      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(outputDescriptor, bytes.baseAddress, bytes.count)
      }
      if count == -1 {
        if errno == EINTR || errno == EAGAIN { continue }
        throw SelfTestError.outputReadFailed(String(cString: strerror(errno)))
      }
      guard count > 0 else {
        throw SelfTestError.helperClosedBeforeMarker
      }
      received.append(contentsOf: buffer.prefix(count))
      if received.range(of: marker) != nil {
        return
      }
    }

    throw SelfTestError.outputTimedOut(shell.id)
  }

  private static func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline {
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

private enum SelfTestError: Error, LocalizedError {
  case missingTestSocket
  case daemonUnavailable
  case createdSessionMissing
  case createdShellMissing
  case unexpectedInitialSession
  case independentSessionChanged
  case independentSessionCloseFailed
  case splitShellSetMismatch
  case splitShellCloseArchivedSession
  case nonLastShellCloseArchivedSession
  case lastShellDidNotReplaceSession
  case replacementSessionMissing
  case helperMissing(String)
  case helperClosedBeforeMarker
  case outputReadFailed(String)
  case outputTimedOut(ShellID)

  var errorDescription: String? {
    switch self {
    case .missingTestSocket:
      "Set AXO_SELF_TEST_SOCKET to an isolated daemon socket before running the app self-test."
    case .daemonUnavailable:
      "axod did not report a running status."
    case .createdSessionMissing:
      "axod did not return the session created by the self-test."
    case .createdShellMissing:
      "axod did not return a shell in the self-test session."
    case .unexpectedInitialSession:
      "axod must start with exactly one default Session before the self-test begins."
    case .independentSessionChanged:
      "Splitting or closing a shell changed an unrelated session."
    case .independentSessionCloseFailed:
      "Closing an unrelated session did not preserve the active split session."
    case .splitShellSetMismatch:
      "The shells returned by axod did not match the expected session layout."
    case .splitShellCloseArchivedSession:
      "Closing a split shell unexpectedly archived its session."
    case .nonLastShellCloseArchivedSession:
      "Closing a shell with another shell still open archived its session."
    case .lastShellDidNotReplaceSession:
      "Closing the last shell did not archive its session and create a replacement."
    case .replacementSessionMissing:
      "The replacement session was not present in axod's active session list."
    case .helperMissing(let path):
      "The terminal-attach helper is missing or not executable at \(path)."
    case .helperClosedBeforeMarker:
      "The terminal-attach helper exited before the test command returned output."
    case .outputReadFailed(let reason):
      "Could not read PTY output: \(reason)"
    case .outputTimedOut(let shellID):
      "Shell \(shellID) did not return PTY output within five seconds."
    }
  }
}
