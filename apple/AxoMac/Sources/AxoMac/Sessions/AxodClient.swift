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
  /// The next batch of events, in order; empty when the long-poll timed out.
  func nextEvents(for subscription: TerminalSubscriptionID) async throws -> [TerminalSessionEvent]
  func unsubscribe(_ subscription: TerminalSubscriptionID) async throws

  func createSession() async throws -> TerminalSession
  func createSession(inWorkspace workspaceID: String) async throws -> TerminalSession
  func createWorkspace(
    name: String, directoryPath: String, directoryBookmark: String?
  ) async throws -> CreatedWorkspace
  func closeSession(_ sessionID: SessionID) async throws -> ClosedTerminalSession
  func renameSession(_ sessionID: SessionID, to name: String) async throws -> TerminalSession
  func renameWorkspace(_ workspaceID: String, to name: String) async throws -> WorkspaceRecord
  func archiveWorkspace(_ workspaceID: String) async throws -> ArchivedWorkspace

  func createShell(inSession sessionID: SessionID) async throws -> TerminalShell
  func closeShell(_ shellID: ShellID, inSession sessionID: SessionID) async throws -> ClosedTerminalShell
  func shellBusy(_ shellID: ShellID, inSession sessionID: SessionID) async throws -> TerminalShellBusy
  func setLayout(_ layout: SessionLayout, forSession sessionID: SessionID) async throws
  func setViewport(_ viewport: ClientViewport) async throws

  func restartPi(shellID: ShellID, inSession sessionID: SessionID, automatically: Bool) async throws
    -> TerminalSession
}

/// The daemon operations Settings depends on, separate from the catalog so settings views never
/// talk to the socket directly and stay testable with fakes.
@MainActor
protocol AxodSettingsClient: AnyObject {
  func configValue(for key: AxoConfigKey) async throws -> AxoConfigValue
  func setConfigValue(_ value: String, for key: AxoConfigKey) async throws -> AxoConfigValue
  func remoteAccessStatus() async throws -> RemoteAccessStatus
  func requestRemoteAccessConnection() async throws
  func linkHost(using code: HostPairingCode) async throws -> HostPairingResult
}

/// `AxodClient` over Axod's local JSON-RPC socket.
@MainActor
final class UnixSocketAxodClient: AxodClient, AxodSettingsClient {
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

  func nextEvents(for subscription: TerminalSubscriptionID) async throws -> [TerminalSessionEvent] {
    try await UnixSocketRPC.nextEvents(
      for: subscription, timeout: Self.eventPollTimeout, at: socketPath)
  }

  func unsubscribe(_ subscription: TerminalSubscriptionID) async throws {
    try await UnixSocketRPC.unsubscribe(subscription, at: socketPath)
  }

  func configValue(for key: AxoConfigKey) async throws -> AxoConfigValue {
    try await UnixSocketRPC.configValue(for: key, at: socketPath)
  }

  func setConfigValue(_ value: String, for key: AxoConfigKey) async throws -> AxoConfigValue {
    try await UnixSocketRPC.setConfigValue(value, for: key, at: socketPath)
  }

  func remoteAccessStatus() async throws -> RemoteAccessStatus {
    try await UnixSocketRPC.remoteAccessStatus(at: socketPath)
  }

  func requestRemoteAccessConnection() async throws {
    try await UnixSocketRPC.requestRemoteAccessConnection(at: socketPath)
  }

  func linkHost(using code: HostPairingCode) async throws -> HostPairingResult {
    try await UnixSocketRPC.linkHost(using: code, at: socketPath)
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

  func closeSession(_ sessionID: SessionID) async throws -> ClosedTerminalSession {
    try await UnixSocketRPC.closeSession(sessionID, at: socketPath)
  }

  func renameSession(_ sessionID: SessionID, to name: String) async throws -> TerminalSession {
    try await UnixSocketRPC.renameSession(sessionID, to: name, at: socketPath)
  }

  func renameWorkspace(_ workspaceID: String, to name: String) async throws -> WorkspaceRecord {
    try await UnixSocketRPC.renameWorkspace(workspaceID, to: name, at: socketPath)
  }

  func archiveWorkspace(_ workspaceID: String) async throws -> ArchivedWorkspace {
    try await UnixSocketRPC.archiveWorkspace(workspaceID, at: socketPath)
  }

  func createShell(inSession sessionID: SessionID) async throws -> TerminalShell {
    try await UnixSocketRPC.createShell(in: sessionID, at: socketPath)
  }

  func closeShell(_ shellID: ShellID, inSession sessionID: SessionID) async throws -> ClosedTerminalShell {
    try await UnixSocketRPC.closeShell(shellID, in: sessionID, at: socketPath)
  }

  func shellBusy(_ shellID: ShellID, inSession sessionID: SessionID) async throws -> TerminalShellBusy {
    try await UnixSocketRPC.shellBusy(shellID, in: sessionID, at: socketPath)
  }

  func setLayout(_ layout: SessionLayout, forSession sessionID: SessionID) async throws {
    try await UnixSocketRPC.setLayout(layout, for: sessionID, at: socketPath)
  }

  func setViewport(_ viewport: ClientViewport) async throws {
    try await UnixSocketRPC.setViewport(viewport, at: socketPath)
  }

  func restartPi(shellID: ShellID, inSession sessionID: SessionID, automatically: Bool) async throws
    -> TerminalSession
  {
    try await UnixSocketRPC.restartPiSession(
      shellID: shellID, in: sessionID, automatically: automatically, at: socketPath)
  }
}
