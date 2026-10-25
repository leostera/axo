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
    // Every method the app calls (negotiation itself just answered), plus the ones other
    // clients rely on.
    for method in AxodMethodName.allCases.filter({ $0 != .negotiate }).map(\.rawValue) + [
      "axo.terminal.input", "axo.terminal.resize",
      "axo.relay.settings", "axo.relay.configure", "axo.relay.disable",
    ] {
      XCTAssertTrue(negotiation.methods.contains(method), "axod should advertise \(method)")
    }
    let viewport = try XCTUnwrap(
      ClientViewport(
        terminalArea: .init(width: 1180.5, height: 742), backingScale: 2,
        cell: .init(width: 16, height: 34),
        padding: .init(top: 10, bottom: 10, left: 2, right: 2), dividerThickness: 1))
    try await UnixSocketRPC.setViewport(viewport, at: socketPath)
    let health = try await UnixSocketRPC.health(at: socketPath)
    XCTAssertEqual(health.version, "0.1.0")
    XCTAssertGreaterThan(health.buildNumber, 0)
    XCTAssertEqual(health.status, "running")

    let relayStatus = try await UnixSocketRPC.remoteAccessStatus(at: socketPath)
    XCTAssertEqual(relayStatus.state, .disconnected)
    XCTAssertFalse(relayStatus.hostName.isEmpty)
    XCTAssertEqual(relayStatus.hostKind, "macos")

    let initialSessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
    XCTAssertEqual(initialSessions.count, 1)
    let baselineSession = try XCTUnwrap(initialSessions.first)
    let baselineShell = try XCTUnwrap(baselineSession.shells.first)
    do {
      _ = try await UnixSocketRPC.restartPiSession(
        shellID: baselineShell.id,
        in: baselineSession.id,
        automatically: false,
        at: socketPath
      )
      XCTFail("restart must reject a terminal pane")
    } catch let error as UnixSocketRPCError {
      guard case .serverRejected(_, let message) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(message, "This Pi pane is no longer available to restart.")
    }

    let renamedBaseline = try await UnixSocketRPC.renameSession(
      baselineSession.id,
      to: "Sidebar label",
      at: socketPath
    )
    XCTAssertEqual(renamedBaseline.manualName, "Sidebar label")
    XCTAssertEqual(renamedBaseline.name, baselineSession.name)

    let createdSession = try await UnixSocketRPC.createSession(at: socketPath)
    XCTAssertNotEqual(createdSession.id, baselineSession.id)
    let createdShell = try await UnixSocketRPC.createShell(in: createdSession.id, at: socketPath)
    let sessionsAfterCreate = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
    XCTAssertEqual(
      Set(sessionsAfterCreate.map(\.id)), Set([baselineSession.id, createdSession.id]))
    let subscription = try await UnixSocketRPC.subscribe(to: createdSession.id, at: socketPath)
    let initialEvents = try await UnixSocketRPC.nextEvents(
      for: subscription,
      timeout: .seconds(1),
      at: socketPath
    )
    guard case .sessionSnapshot(let snapshot) = initialEvents.first else {
      return XCTFail("subscription should begin with a current session snapshot")
    }
    XCTAssertEqual(snapshot.id, createdSession.id)
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
    let remainingSessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
    XCTAssertEqual(remainingSessions.map(\.id), [baselineSession.id])
  }

  func testTerminalAttachmentsShareOneShellWithoutReadingThePTY() async throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("axo-attach-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    let sessions = try await UnixSocketRPC.listSessionSnapshot(at: socketPath).sessions
    let session = try XCTUnwrap(sessions.first)
    let shell = try XCTUnwrap(session.shells.first)
    let attachSocket = try UnixSocketPath(shell.attachSocketPath)
    let first = try TerminalAttachment.open(socketPath: attachSocket, shellID: shell.id)
    defer { first.close() }
    let second = try TerminalAttachment.open(socketPath: attachSocket, shellID: shell.id)
    defer { second.close() }

    // Input goes to the PTY descriptor; output arrives on every attachment's stream.
    let command = Array("printf '%s%s\\n' AXO_SWIFT_ ATTACH_OK\n".utf8)
    XCTAssertEqual(command.withUnsafeBytes { write(first.ptyDescriptor, $0.baseAddress, $0.count) }, command.count)
    for attachment in [first, second] {
      XCTAssertTrue(
        readUntil(attachment.outputDescriptor, contains: "AXO_SWIFT_ATTACH_OK", timeout: 5),
        "every attachment should receive the shell's output")
    }

    let third = try TerminalAttachment.open(socketPath: attachSocket, shellID: shell.id)
    defer { third.close() }
    XCTAssertGreaterThan(third.replayByteCount, 0)
    XCTAssertTrue(
      readUntil(third.outputDescriptor, contains: "AXO_SWIFT_ATTACH_OK", timeout: 5),
      "a late attachment should replay earlier output")

    do {
      _ = try TerminalAttachment.open(socketPath: attachSocket, shellID: ShellID(rawValue: 999_999))
      XCTFail("attaching to an unknown shell must be rejected")
    } catch let error as TerminalAttachmentError {
      XCTAssertEqual(error, .rejected(.shellNotOpen))
    }
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

private func readUntil(_ descriptor: Int32, contains needle: String, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  var received = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while Date() < deadline {
    var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&poller, 1, 100) > 0 else { continue }
    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
    guard count > 0 else { return false }
    received.append(contentsOf: buffer[0..<count])
    if String(decoding: received, as: UTF8.self).contains(needle) { return true }
  }
  return false
}
