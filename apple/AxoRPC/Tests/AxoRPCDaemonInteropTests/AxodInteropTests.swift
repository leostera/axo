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
    daemon.arguments = ["--socket", socketPath.value]
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = FileHandle.nullDevice
    try daemon.run()
    defer {
      if daemon.isRunning {
        daemon.terminate()
        daemon.waitUntilExit()
      }
    }

    try await waitForSocket(at: socketPath, from: daemon)
    let health = try await UnixSocketRPC.health(at: socketPath)
    XCTAssertGreaterThan(health.buildNumber, 0)
    XCTAssertEqual(health.status, "running")
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
