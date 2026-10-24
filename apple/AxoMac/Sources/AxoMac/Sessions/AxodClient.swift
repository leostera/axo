import AxoRPC
import Foundation

/// The daemon operations the session catalog depends on. Production uses
/// `UnixSocketAxodClient`; tests inject in-memory fakes, so catalog/selection/layout logic is
/// testable without sockets or processes.
@MainActor
protocol AxodClient: AnyObject {
  func negotiate() async throws -> ProtocolNegotiation
  func listSessionSnapshot() async throws -> TerminalSessionListSnapshot
  func listWorkspaces() async throws -> [WorkspaceRecord]

  func subscribeToCatalog() async throws -> TerminalSubscriptionID
  func nextEvent(for subscription: TerminalSubscriptionID) async throws -> TerminalSessionEvent?
  func unsubscribe(_ subscription: TerminalSubscriptionID) async throws

  func createSession() async throws -> TerminalSession
  func createSession(inWorkspace workspaceID: String) async throws -> TerminalSession
  func createWorkspace(
    name: String, directoryPath: String, directoryBookmark: String?
  ) async throws -> CreatedWorkspace
  func closeSession(_ sessionID: Int64) async throws -> ClosedTerminalSession
  func renameSession(_ sessionID: Int64, to name: String) async throws -> TerminalSession
  func renameWorkspace(_ workspaceID: String, to name: String) async throws -> WorkspaceRecord
  func archiveWorkspace(_ workspaceID: String) async throws -> ArchivedWorkspace

  func createShell(inSession sessionID: Int64) async throws -> TerminalShell
  func closeShell(_ shellID: Int64, inSession sessionID: Int64) async throws -> ClosedTerminalShell
  func setLayout(_ layout: SessionLayout, forSession sessionID: Int64) async throws

  func restartPi(shellID: Int64, inSession sessionID: Int64, automatically: Bool) async throws
    -> TerminalSession
}

/// `AxodClient` over Axod's local JSON-RPC socket.
@MainActor
final class UnixSocketAxodClient: AxodClient {
  /// Long-poll window; the daemon caps waits at 20 seconds.
  static let eventPollTimeout: Duration = .seconds(15)

  let socketPath: UnixSocketPath

  init(socketPath: UnixSocketPath) {
    self.socketPath = socketPath
  }

  func negotiate() async throws -> ProtocolNegotiation {
    try await UnixSocketRPC.negotiate(at: socketPath)
  }

  func listSessionSnapshot() async throws -> TerminalSessionListSnapshot {
    try await UnixSocketRPC.listSessionSnapshot(at: socketPath)
  }

  func listWorkspaces() async throws -> [WorkspaceRecord] {
    try await UnixSocketRPC.listWorkspaces(at: socketPath)
  }

  func subscribeToCatalog() async throws -> TerminalSubscriptionID {
    try await UnixSocketRPC.subscribe(includeTerminalOutput: false, at: socketPath)
  }

  func nextEvent(for subscription: TerminalSubscriptionID) async throws -> TerminalSessionEvent? {
    try await UnixSocketRPC.nextEvent(
      for: subscription, timeout: Self.eventPollTimeout, at: socketPath)
  }

  func unsubscribe(_ subscription: TerminalSubscriptionID) async throws {
    try await UnixSocketRPC.unsubscribe(subscription, at: socketPath)
  }

  func createSession() async throws -> TerminalSession {
    try await UnixSocketRPC.createSession(at: socketPath)
  }

  func createSession(inWorkspace workspaceID: String) async throws -> TerminalSession {
    try await UnixSocketRPC.createSession(in: workspaceID, at: socketPath)
  }

  func createWorkspace(
    name: String, directoryPath: String, directoryBookmark: String?
  ) async throws -> CreatedWorkspace {
    try await UnixSocketRPC.createWorkspace(
      name: name, directoryPath: directoryPath, directoryBookmark: directoryBookmark,
      at: socketPath)
  }

  func closeSession(_ sessionID: Int64) async throws -> ClosedTerminalSession {
    try await UnixSocketRPC.closeSession(sessionID, at: socketPath)
  }

  func renameSession(_ sessionID: Int64, to name: String) async throws -> TerminalSession {
    try await UnixSocketRPC.renameSession(sessionID, to: name, at: socketPath)
  }

  func renameWorkspace(_ workspaceID: String, to name: String) async throws -> WorkspaceRecord {
    try await UnixSocketRPC.renameWorkspace(workspaceID, to: name, at: socketPath)
  }

  func archiveWorkspace(_ workspaceID: String) async throws -> ArchivedWorkspace {
    try await UnixSocketRPC.archiveWorkspace(workspaceID, at: socketPath)
  }

  func createShell(inSession sessionID: Int64) async throws -> TerminalShell {
    try await UnixSocketRPC.createShell(in: sessionID, at: socketPath)
  }

  func closeShell(_ shellID: Int64, inSession sessionID: Int64) async throws -> ClosedTerminalShell {
    try await UnixSocketRPC.closeShell(shellID, in: sessionID, at: socketPath)
  }

  func setLayout(_ layout: SessionLayout, forSession sessionID: Int64) async throws {
    try await UnixSocketRPC.setLayout(layout, for: sessionID, at: socketPath)
  }

  func restartPi(shellID: Int64, inSession sessionID: Int64, automatically: Bool) async throws
    -> TerminalSession
  {
    if automatically {
      return try await UnixSocketRPC.automaticallyRestartPiSession(
        shellID: shellID, in: sessionID, at: socketPath)
    }
    return try await UnixSocketRPC.restartPiSession(
      shellID: shellID, in: sessionID, at: socketPath)
  }
}
