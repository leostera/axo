import Darwin
import Foundation
import XCTest

import AxoProtocol
@testable import AxoClient

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
    let daemon = try startAxod(socket: socketPath, in: directory)
    defer { stop(daemon) }

    try await waitForSocket(at: socketPath, from: daemon)
    let axod = AxodConnection(socketPath: socketPath)
    let negotiation = try await axod.negotiate()
    XCTAssertEqual(negotiation.protocolVersion, ProtocolNegotiation.supportedVersion)
    // Every method the app calls (negotiation itself just answered), plus the ones other
    // clients rely on.
    for method in AxodMethodName.allCases.filter({ $0 != .negotiate }).map(\.rawValue) + [
      "axo.terminal.input", "axo.terminal.resize",
    ] {
      XCTAssertTrue(negotiation.methods.contains(method), "axod should advertise \(method)")
    }
    let viewport = try XCTUnwrap(
      ClientViewport(
        terminalArea: .init(width: 1180.5, height: 742), backingScale: 2,
        cell: .init(width: 16, height: 34),
        padding: .init(top: 10, bottom: 10, left: 2, right: 2), dividerThickness: 1))
    try await axod.setViewport(viewport)
    let health = try await axod.health()
    XCTAssertEqual(health.version, "0.1.0")
    XCTAssertGreaterThan(health.buildNumber, 0)
    XCTAssertEqual(health.status, "running")

    let relayStatus = try await axod.remoteAccessStatus()
    XCTAssertEqual(relayStatus.state, .disconnected)
    XCTAssertFalse(relayStatus.hostName.isEmpty)
    XCTAssertEqual(relayStatus.hostKind, "macos")

    let initialSessions = try await axod.listSessionSnapshot().sessions
    XCTAssertEqual(initialSessions.count, 1)
    let baselineSession = try XCTUnwrap(initialSessions.first)
    // The Home Session starts with Pi beside a terminal.
    let baselineShell = try XCTUnwrap(baselineSession.shells.first { $0.role == .terminal })
    do {
      _ = try await axod.restartPi(
        shellID: baselineShell.id,
        inSession: baselineSession.id,
        automatically: false)
      XCTFail("restart must reject a terminal pane")
    } catch let error as AxoClientError {
      guard case .serverRejected(_, let message) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(message, "This Pi pane is no longer available to restart.")
    }

    let renamedBaseline = try await axod.renameSession(
      baselineSession.id,
      to: "Sidebar label")
    XCTAssertEqual(renamedBaseline.manualName, "Sidebar label")
    XCTAssertEqual(renamedBaseline.name, baselineSession.name)

    let createdSession = try await axod.createSession()
    XCTAssertNotEqual(createdSession.id, baselineSession.id)
    let createdShell = try await axod.createShell(inSession: createdSession.id)
    let sessionsAfterCreate = try await axod.listSessionSnapshot().sessions
    XCTAssertEqual(
      Set(sessionsAfterCreate.map(\.id)), Set([baselineSession.id, createdSession.id]))
    let subscription = try await axod.subscribe(to: createdSession.id, includeTerminalOutput: true)
    let initialEvents = try await axod.nextEvents(
      for: subscription,
      timeout: .seconds(1),
      maxEvents: AxodConnection.maxEventsPerPoll)
    guard case .sessionSnapshot(let snapshot) = initialEvents.first else {
      return XCTFail("subscription should begin with a current session snapshot")
    }
    XCTAssertEqual(snapshot.id, createdSession.id)
    try await axod.unsubscribe(subscription)
    XCTAssertEqual(
      sessionsAfterCreate.first(where: { $0.id == createdSession.id })?.shells.map(\.id),
      createdSession.shells.map(\.id) + [createdShell.id]
    )

    let closedShell = try await axod.closeShell(
      createdShell.id,
      inSession: createdSession.id)
    XCTAssertEqual(closedShell.archivedShellId, createdShell.id)
    XCTAssertNil(closedShell.archivedSessionId)

    let closedSession = try await axod.closeSession(createdSession.id)
    XCTAssertEqual(closedSession.archivedSessionId, createdSession.id)
    XCTAssertNil(closedSession.replacement)
    let remainingSessions = try await axod.listSessionSnapshot().sessions
    XCTAssertEqual(remainingSessions.map(\.id), [baselineSession.id])
  }

  /// One connection carries many calls at once: a long-poll waiting on it holds up nothing.
  func testALongPollDoesNotHoldUpOtherCallsOnTheSameConnection() async throws {
    try await withDaemon { axod in
      let subscription = try await axod.subscribe(to: nil, includeTerminalOutput: false)
      // The first poll returns the current snapshot; the next one waits.
      _ = try await axod.nextEvents(for: subscription, timeout: .seconds(1), maxEvents: 256)
      let started = ContinuousClock.now
      async let quiet = axod.nextEvents(for: subscription, timeout: .seconds(3), maxEvents: 256)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<32 {
          group.addTask { _ = try await axod.listSessionSnapshot() }
        }
        try await group.waitForAll()
      }
      let callsTook = ContinuousClock.now - started
      XCTAssertLessThan(callsTook, .seconds(2), "32 calls waited on the long-poll: \(callsTook)")
      let events = try await quiet
      XCTAssertEqual(events.count, 0)
      XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(2_900))
    }
  }

  /// Opt-in: `AXO_RUN_BENCHMARKS=1`. Sequential calls on one persistent connection against a
  /// fresh connection per call (how the client worked before `AxodConnection`).
  func testBenchmarkPersistentConnectionAgainstConnectionPerCall() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["AXO_RUN_BENCHMARKS"] == "1",
      "Benchmarks run only with AXO_RUN_BENCHMARKS=1.")
    try await withDaemon { axod, socketPath in
      let calls = 500
      func measure(_ call: () async throws -> Void) async throws -> [Double] {
        var samples: [Double] = []
        for _ in 0..<calls {
          let start = ContinuousClock.now
          try await call()
          let elapsed = ContinuousClock.now - start
          samples.append(Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6)
        }
        return samples.sorted()
      }
      _ = try await axod.negotiate()
      let persistent = try await measure { _ = try await axod.listSessionSnapshot() }
      let perCall = try await measure {
        _ = try await AxodConnection.withFreshConnection(to: socketPath) {
          try await $0.listSessionSnapshot()
        }
      }
      for (name, samples) in [("persistent", persistent), ("per_call", perCall)] {
        print(
          "BENCH session_list_us mode=\(name) n=\(calls) p50=\(Int(samples[calls / 2])) p90=\(Int(samples[calls * 9 / 10])) p99=\(Int(samples[calls * 99 / 100]))")
      }
    }
  }

  private func withDaemon(_ body: (AxodConnection) async throws -> Void) async throws {
    try await withDaemon { axod, _ in try await body(axod) }
  }

  private func withDaemon(_ body: (AxodConnection, UnixSocketPath) async throws -> Void)
    async throws
  {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("axo-conn-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketPath = try UnixSocketPath(directory.appendingPathComponent("axod.sock").path)
    let daemon = try startAxod(socket: socketPath, in: directory)
    defer { stop(daemon) }
    try await waitForSocket(at: socketPath, from: daemon)
    let axod = AxodConnection(socketPath: socketPath)
    try await body(axod, socketPath)
    await axod.disconnect()
  }

  func testTerminalAttachmentsShareOneShellWithoutReadingThePTY() async throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("axo-attach-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketPath = try UnixSocketPath(directory.appendingPathComponent("axod.sock").path)
    let daemon = try startAxod(socket: socketPath, in: directory)
    defer { stop(daemon) }
    try await waitForSocket(at: socketPath, from: daemon)
    let axod = AxodConnection(socketPath: socketPath)

    let sessions = try await axod.listSessionSnapshot().sessions
    let session = try XCTUnwrap(sessions.first)
    let shell = try XCTUnwrap(session.shells.first { $0.role == .terminal })
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

/// Starts Axod with its catalog in `directory`. Pi panes run the declared inert fixtures, never
/// the developer's Pi or extension: without an extension Axod cannot start a Workspace Session,
/// and a test expecting the Home Session would find none.
private func startAxod(socket: UnixSocketPath, in directory: URL) throws -> Process {
  let home = directory.appendingPathComponent("home", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  let daemon = Process()
  daemon.executableURL = try runfile(named: "AXOD_BINARY", executable: true)
  daemon.arguments = [
    "--socket", socket.value,
    "--server-dir", directory.appendingPathComponent("server").path,
  ]
  var environment = ProcessInfo.processInfo.environment
  environment["HOME"] = home.path
  environment["AXO_PI_EXTENSION_PATH"] = try runfile(
    named: "AXO_PI_EXTENSION_PATH", executable: false
  ).path
  environment["AXO_PI_EXECUTABLE"] = try runfile(named: "AXO_TEST_PI_EXECUTABLE", executable: true)
    .path
  daemon.environment = environment
  daemon.standardOutput = FileHandle.nullDevice
  daemon.standardError = FileHandle.nullDevice
  try daemon.run()
  return daemon
}

/// The runfile whose path the test environment variable `name` holds.
private func runfile(named name: String, executable: Bool) throws -> URL {
  let environment = ProcessInfo.processInfo.environment
  guard let configuredPath = environment[name] else {
    throw AxodInteropError.missingRunfile(name)
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

  guard
    let executable = candidates.first(where: {
      executable
        ? fileManager.isExecutableFile(atPath: $0.path) : fileManager.fileExists(atPath: $0.path)
    })
  else {
    throw AxodInteropError.runfileNotFound(configuredPath)
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
    if socketAcceptsConnections(atPath: socketPath.value) {
      return
    }
    guard daemon.isRunning else { throw AxodInteropError.daemonExitedEarly }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  throw AxoClientError.requestTimedOut
}

/// Whether a Unix-domain socket at `path` accepts connections. Its file exists from `bind()`,
/// before axod's `listen()`; a connect between the two is refused, so existence is not readiness.
private func socketAcceptsConnections(atPath path: String) -> Bool {
  let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { return false }
  defer { Darwin.close(descriptor) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: bytes)
  }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
    }
  }
}

private enum AxodInteropError: LocalizedError {
  case missingRunfile(String)
  case runfileNotFound(String)
  case daemonExitedEarly

  var errorDescription: String? {
    switch self {
    case .missingRunfile(let name):
      "Bazel must provide \(name) to the interop test."
    case .runfileNotFound(let path):
      "Could not resolve \(path) from Bazel runfiles."
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
