import Darwin
import Foundation
import XCTest

@testable import AxoRPC

final class AxodInteropTests: XCTestCase {
  func testRustDaemonSpeaksSwiftJsonRpcClient() async throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("axo-interop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let socketPath = try UnixSocketPath(directory.appendingPathComponent("axod.sock").path)
    let daemon = Process()
    daemon.executableURL = try axodExecutable()
    daemon.arguments = [
      "--socket", socketPath.value,
      "--server-dir", directory.appendingPathComponent("server").path,
    ]
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = FileHandle.nullDevice
    try daemon.run()
    defer { stop(daemon) }

    try await waitForSocket(at: socketPath, from: daemon)
    let negotiation = try await UnixSocketRPC.negotiate(at: socketPath)
    XCTAssertEqual(negotiation.protocolVersion, UnixSocketRPC.protocolVersion)
    for method in [
      "axo.session.create", "axo.session.subscribe", "axo.session.events.next",
      "axo.session.unsubscribe", "axo.terminal.input", "axo.terminal.resize",
      "axo.relay.settings", "axo.relay.configure", "axo.relay.disable",
      "axo.relay.status", "axo.relay.connect",
    ] {
      XCTAssertTrue(negotiation.methods.contains(method), "axod should advertise \(method)")
    }
    let health = try await UnixSocketRPC.health(at: socketPath)
    XCTAssertEqual(health.version, "0.1.0")
    XCTAssertGreaterThan(health.buildNumber, 0)
    XCTAssertEqual(health.status, "running")

    let relaySettings = try await UnixSocketRPC.remoteAccessSettings(at: socketPath)
    XCTAssertFalse(relaySettings.enabled)
    let relayStatus = try await UnixSocketRPC.remoteAccessStatus(at: socketPath)
    XCTAssertEqual(relayStatus.state, .disconnected)
    XCTAssertFalse(relayStatus.hostName.isEmpty)
    XCTAssertEqual(relayStatus.hostKind, "macos")
    try await UnixSocketRPC.disableRemoteAccess(at: socketPath)

    let initialSessions = try await UnixSocketRPC.listSessions(at: socketPath)
    XCTAssertEqual(initialSessions.count, 1)

    let createdSession = try await UnixSocketRPC.createSession(at: socketPath)
    XCTAssertNotEqual(createdSession.id, initialSessions[0].id)
    let createdShell = try await UnixSocketRPC.createShell(in: createdSession.id, at: socketPath)
    let sessionsAfterCreate = try await UnixSocketRPC.listSessions(at: socketPath)
    XCTAssertEqual(
      Set(sessionsAfterCreate.map(\.id)), Set([initialSessions[0].id, createdSession.id]))
    let subscription = try await UnixSocketRPC.subscribe(to: createdSession.id, at: socketPath)
    let initialEvent = try await UnixSocketRPC.nextEvent(
      for: subscription,
      timeout: .seconds(1),
      at: socketPath
    )
    guard case .sessionSnapshot(let snapshot) = initialEvent else {
      return XCTFail("subscription should begin with a current session snapshot")
    }
    XCTAssertEqual(snapshot.id, createdSession.id)
    try await UnixSocketRPC.resizeTerminal(
      shellID: createdShell.id,
      in: createdSession.id,
      rows: 44,
      columns: 120,
      at: socketPath
    )
    try await UnixSocketRPC.sendTerminalInput(
      Data("echo AXO_SWIFT_PROTOCOL_INPUT\n".utf8),
      to: createdShell.id,
      in: createdSession.id,
      sequence: 0,
      at: socketPath
    )
    try await UnixSocketRPC.unsubscribe(subscription, at: socketPath)
    XCTAssertEqual(
      sessionsAfterCreate.first(where: { $0.id == createdSession.id })?.shells.map(\.id),
      [createdSession.shells[0].id, createdShell.id]
    )

    let closedShell = try await UnixSocketRPC.closeShell(
      createdShell.id,
      in: createdSession.id,
      at: socketPath
    )
    XCTAssertEqual(closedShell.archivedShellId, createdShell.id)
    XCTAssertNil(closedShell.archivedSessionId)

    let closedSession = try await UnixSocketRPC.closeSession(createdSession.id, at: socketPath)
    XCTAssertEqual(closedSession.archivedSessionId, createdSession.id)
    XCTAssertNil(closedSession.replacement)
    let remainingSessions = try await UnixSocketRPC.listSessions(at: socketPath)
    XCTAssertEqual(remainingSessions.map(\.id), [initialSessions[0].id])
  }
}

private func axodExecutable() throws -> URL {
  let environment = ProcessInfo.processInfo.environment
  guard let configuredPath = environment["AXOD_BINARY"] else {
    throw AxodInteropError.missingBinaryPath
  }

  let fileManager = FileManager.default
  let binaryURL = URL(fileURLWithPath: configuredPath)
  var candidates = [binaryURL]

  if let runfilesPath = environment["RUNFILES_DIR"] ?? environment["TEST_SRCDIR"] {
    let runfiles = URL(fileURLWithPath: runfilesPath, isDirectory: true)
    candidates.append(runfiles.appendingPathComponent(configuredPath))
    if let workspace = environment["TEST_WORKSPACE"] {
      candidates.append(
        runfiles.appendingPathComponent(workspace).appendingPathComponent(configuredPath))
    }
    candidates.append(
      runfiles.appendingPathComponent("_main").appendingPathComponent(configuredPath))
  }

  guard let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
  else {
    throw AxodInteropError.binaryNotFound(configuredPath)
  }
  return executable
}

private func stop(_ process: Process) {
  guard process.isRunning else { return }
  let exited = DispatchSemaphore(value: 0)
  process.terminationHandler = { _ in exited.signal() }
  process.terminate()
  guard exited.wait(timeout: .now() + 3) == .timedOut else { return }

  _ = Darwin.kill(process.processIdentifier, SIGKILL)
  XCTAssertEqual(
    exited.wait(timeout: .now() + 3),
    .success,
    "axod did not exit within three seconds after SIGKILL"
  )
}

private func waitForSocket(at socketPath: UnixSocketPath, from daemon: Process) async throws {
  for _ in 0..<250 {
    if FileManager.default.fileExists(atPath: socketPath.value) {
      return
    }
    guard daemon.isRunning else { throw AxodInteropError.daemonExitedEarly }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  throw UnixSocketRPCError.requestTimedOut
}

private enum AxodInteropError: LocalizedError {
  case missingBinaryPath
  case binaryNotFound(String)
  case daemonExitedEarly

  var errorDescription: String? {
    switch self {
    case .missingBinaryPath:
      "Bazel must provide AXOD_BINARY to the interop test."
    case .binaryNotFound(let path):
      "Could not resolve axod from Bazel runfiles at \(path)."
    case .daemonExitedEarly:
      "axod exited before creating its Unix-domain socket."
    }
  }
}
