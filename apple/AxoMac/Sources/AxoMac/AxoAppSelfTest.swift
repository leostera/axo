import AxoRPC
import Darwin
import Foundation

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

    let session = try await UnixSocketRPC.createSession(at: socketPath)
    do {
      let sessions = try await UnixSocketRPC.listSessions(at: socketPath)
      guard sessions.contains(where: { $0.id == session.id }) else {
        throw SelfTestError.createdSessionMissing
      }
      try verifyPTYAttachment(session, helperURL: helperURL)
      let closed = try await UnixSocketRPC.closeSession(session.id, at: socketPath)
      guard closed.archivedSessionId == session.id else {
        throw SelfTestError.closeDidNotArchiveSession
      }
    } catch {
      _ = try? await UnixSocketRPC.closeSession(session.id, at: socketPath)
      throw error
    }
  }

  private static func verifyPTYAttachment(
    _ session: TerminalSession,
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
      "--attach-socket", session.attachSocketPath,
      "--session-id", String(session.id),
    ]
    helper.standardInput = input
    helper.standardOutput = output
    helper.standardError = FileHandle.nullDevice
    try helper.run()
    defer { stop(helper) }

    try input.fileHandleForWriting.write(
      contentsOf: Data("printf '\(successMarker)\\n'\n".utf8)
    )

    let outputDescriptor = output.fileHandleForReading.fileDescriptor
    let deadline = Date().addingTimeInterval(5)
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let marker = Data(successMarker.utf8)

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

    throw SelfTestError.outputTimedOut
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
  case closeDidNotArchiveSession
  case helperMissing(String)
  case helperClosedBeforeMarker
  case outputReadFailed(String)
  case outputTimedOut

  var errorDescription: String? {
    switch self {
    case .missingTestSocket:
      "Set AXO_SELF_TEST_SOCKET to an isolated daemon socket before running the app self-test."
    case .daemonUnavailable:
      "Axo D did not report a running status."
    case .createdSessionMissing:
      "Axo D did not return the session created by the self-test."
    case .closeDidNotArchiveSession:
      "Axo D did not archive the self-test session."
    case .helperMissing(let path):
      "The terminal-attach helper is missing or not executable at \(path)."
    case .helperClosedBeforeMarker:
      "The terminal-attach helper exited before the test command returned output."
    case .outputReadFailed(let reason):
      "Could not read PTY output: \(reason)"
    case .outputTimedOut:
      "The test command did not return PTY output within five seconds."
    }
  }
}
