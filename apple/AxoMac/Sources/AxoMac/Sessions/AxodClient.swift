import AxoProtocol
import AxoClient
import Foundation

/// The daemon operations the session catalog depends on. Production uses `AxodConnection`;
/// tests inject in-memory fakes, so catalog/selection/layout logic is
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

/// Production's client: one persistent connection to the local Axod (see `AxoClient`). The
/// remaining methods already match.
extension AxodConnection: AxodClient, AxodSettingsClient {
  /// Long-poll window; the daemon caps waits at 20 seconds.
  static let eventPollTimeout: Duration = .seconds(15)

  func subscribeToCatalog() async throws -> TerminalSubscriptionID {
    try await subscribe(to: nil, includeTerminalOutput: false)
  }

  func nextEvents(for subscription: TerminalSubscriptionID) async throws -> [TerminalSessionEvent] {
    try await nextEvents(
      for: subscription, timeout: Self.eventPollTimeout, maxEvents: Self.maxEventsPerPoll)
  }
}
