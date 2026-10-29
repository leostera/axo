import AxoProtocol
import Foundation

/// axod's local API over any transport, on one persistent connection.
///
/// Each method shapes its arguments and checks what the host returned beyond decoding (a result
/// for the key or Session asked about, an acknowledgement that is actually positive), so callers
/// only see well-formed answers or an `AxoClientError`.
public final class AxodConnection: Sendable {
  /// The daemon's per-poll batch limit.
  public static let maxEventsPerPoll = 256

  private let rpc: JSONRPCConnection

  public init(transport: any AxoTransport) {
    rpc = JSONRPCConnection(transport: transport)
  }

  /// To the local axod listening on `socketPath`.
  public convenience init(socketPath: UnixSocketPath) {
    self.init(transport: UnixSocketTransport(socketPath: socketPath))
  }

  /// Runs `body` on a connection of its own, closed afterwards: for probes that must test a
  /// fresh connection, such as health checks while axod may be restarting.
  public static func withFreshConnection<Result>(
    to socketPath: UnixSocketPath, _ body: (AxodConnection) async throws -> Result
  ) async throws -> Result {
    let connection = AxodConnection(socketPath: socketPath)
    do {
      let result = try await body(connection)
      await connection.disconnect()
      return result
    } catch {
      await connection.disconnect()
      throw error
    }
  }

  /// Closes the connection; calls in flight fail and the next call reconnects.
  public func disconnect() async {
    await rpc.disconnect()
  }

  // MARK: - Host

  public func negotiate() async throws -> ProtocolNegotiation {
    try await call(
      AxodMethods.negotiate,
      ProtocolNegotiationRequest(protocolVersion: ProtocolNegotiation.supportedVersion))
  }

  public func health() async throws -> DaemonHealth {
    let health = try await call(AxodMethods.health)
    if let version = health.version, version.isEmpty {
      throw AxoClientError.invalidResponse("daemon version must not be empty")
    }
    guard health.status == "running" else {
      throw AxoClientError.invalidResponse("daemon status was not running")
    }
    guard BuildNumber(health.buildNumber) != nil else {
      throw AxoClientError.invalidResponse("build number must be positive")
    }
    return health
  }

  public func configValue(for key: AxoConfigKey) async throws -> AxoConfigValue {
    let value = try await call(AxodMethods.configGet, ConfigGetRequest(key: key))
    guard value.key == key else {
      throw AxoClientError.invalidResponse("daemon returned configuration for a different key")
    }
    return value
  }

  public func setConfigValue(_ value: String, for key: AxoConfigKey) async throws
    -> AxoConfigValue
  {
    let saved = try await call(AxodMethods.configSet, ConfigSetRequest(key: key, value: value))
    guard saved.key == key else {
      throw AxoClientError.invalidResponse("daemon saved configuration under a different key")
    }
    return saved
  }

  public func setViewport(_ viewport: ClientViewport) async throws {
    guard try await call(AxodMethods.clientViewportSet, viewport).accepted else {
      throw AxoClientError.invalidResponse("daemon did not accept the viewport")
    }
  }

  // MARK: - Remote access

  public func remoteAccessStatus() async throws -> RemoteAccessStatus {
    try await call(AxodMethods.relayStatus)
  }

  public func requestRemoteAccessConnection() async throws {
    guard try await call(AxodMethods.relayConnect).requested else {
      throw AxoClientError.invalidResponse("axod has no remote relay configured")
    }
  }

  public func linkHost(using code: HostPairingCode) async throws -> HostPairingResult {
    let result = try await call(AxodMethods.relayLink, HostPairingRequest(code: code.value))
    guard result.linked, !result.hostLabel.isEmpty else {
      throw AxoClientError.invalidResponse("axod did not confirm host pairing")
    }
    return result
  }

  // MARK: - Sessions and Workspaces

  public func listSessionSnapshot() async throws -> TerminalSessionListSnapshot {
    try await call(AxodMethods.sessionList)
  }

  public func listWorkspaces() async throws -> [WorkspaceRecord] {
    try await call(AxodMethods.workspaceList).workspaces
  }

  public func createSession() async throws -> TerminalSession {
    try await call(AxodMethods.sessionCreate)
  }

  public func createSession(inWorkspace workspaceID: String) async throws -> TerminalSession {
    try await call(
      AxodMethods.workspaceSessionCreate, WorkspaceSessionCreateRequest(workspaceId: workspaceID))
  }

  public func createWorkspace(
    name: String, directoryPath: String, directoryBookmark: String?
  ) async throws -> CreatedWorkspace {
    try await call(
      AxodMethods.workspaceCreate,
      WorkspaceCreateRequest(
        name: name, directoryPath: directoryPath, directoryBookmark: directoryBookmark))
  }

  public func closeSession(_ sessionID: SessionID) async throws -> ClosedTerminalSession {
    try await call(AxodMethods.sessionClose, CloseTerminalSessionRequest(sessionId: sessionID))
  }

  /// Reopens the Session most recently closed on this Mac. Axod rejects it with
  /// `sessionNotReopenedCode` when no closed Session can be reopened.
  public func reopenClosedSession() async throws -> TerminalSession {
    try await call(AxodMethods.sessionReopen)
  }

  /// `axo.session.reopen`'s error when there is no closed Session it can reopen.
  public static let sessionNotReopenedCode = -32005

  public func renameSession(_ sessionID: SessionID, to name: String) async throws
    -> TerminalSession
  {
    try await call(
      AxodMethods.sessionRename, SessionRenameRequest(sessionId: sessionID, name: name))
  }

  public func renameWorkspace(_ workspaceID: String, to name: String) async throws
    -> WorkspaceRecord
  {
    try await call(
      AxodMethods.workspaceRename, WorkspaceRenameRequest(workspaceId: workspaceID, name: name))
  }

  public func archiveWorkspace(_ workspaceID: String) async throws -> ArchivedWorkspace {
    try await call(
      AxodMethods.workspaceArchive, WorkspaceArchiveRequest(workspaceId: workspaceID))
  }

  public func setLayout(_ layout: SessionLayout, forSession sessionID: SessionID) async throws {
    let acknowledgement = try await call(
      AxodMethods.sessionLayoutSet, SetSessionLayoutRequest(sessionId: sessionID, layout: layout))
    guard acknowledgement.saved else {
      throw AxoClientError.invalidResponse("daemon did not save the session layout")
    }
  }

  /// Explicit Restart Pi (`automatically: false`) or the idle-only, non-forcing automatic
  /// recovery (`true`).
  public func restartPi(shellID: ShellID, inSession sessionID: SessionID, automatically: Bool)
    async throws -> TerminalSession
  {
    try await call(
      automatically ? AxodMethods.piRestartAuto : AxodMethods.piRestartForce,
      RestartPiSessionRequest(sessionId: sessionID, shellId: shellID))
  }

  // MARK: - Shells

  public func createShell(inSession sessionID: SessionID) async throws -> TerminalShell {
    try await call(AxodMethods.shellCreate, CreateTerminalShellRequest(sessionId: sessionID))
  }

  public func closeShell(_ shellID: ShellID, inSession sessionID: SessionID) async throws
    -> ClosedTerminalShell
  {
    try await call(AxodMethods.shellClose, ShellRequest(sessionId: sessionID, shellId: shellID))
  }

  public func shellBusy(_ shellID: ShellID, inSession sessionID: SessionID) async throws
    -> TerminalShellBusy
  {
    try await call(AxodMethods.shellBusy, ShellRequest(sessionId: sessionID, shellId: shellID))
  }

  // MARK: - Events

  /// Opens an event subscription. Catalog consumers pass `includeTerminalOutput: false` to
  /// receive only catalog events (no terminal output or Pi stream events).
  public func subscribe(to sessionID: SessionID?, includeTerminalOutput: Bool) async throws
    -> TerminalSubscriptionID
  {
    try await call(
      AxodMethods.sessionSubscribe,
      SessionSubscribeRequest(sessionId: sessionID, includeTerminalOutput: includeTerminalOutput))
  }

  /// Waits up to `timeout` (at most 20 s) for the next event and returns it with any already
  /// queued after it, in order. An empty result means the wait timed out.
  public func nextEvents(
    for subscription: TerminalSubscriptionID, timeout: Duration, maxEvents: Int
  ) async throws -> [TerminalSessionEvent] {
    let timeoutMilliseconds = min(20_000, max(1, timeout.milliseconds))
    let request = SessionEventsNextRequest(
      subscriptionId: subscription.subscriptionId,
      timeoutMs: UInt64(timeoutMilliseconds),
      maxEvents: min(Self.maxEventsPerPoll, max(1, maxEvents)))
    // The call outlives the server-side wait by a second.
    return try await call(
      AxodMethods.sessionEventsNext, request,
      timeout: .milliseconds(timeoutMilliseconds + 1_000)
    ).events
  }

  public func unsubscribe(_ subscription: TerminalSubscriptionID) async throws {
    let response = try await call(
      AxodMethods.sessionUnsubscribe,
      SessionUnsubscribeRequest(subscriptionId: subscription.subscriptionId))
    guard response.unsubscribed else {
      throw AxoClientError.invalidResponse("daemon did not unsubscribe the session event stream")
    }
  }

  // MARK: - Calls

  private func call<Params, Result>(
    _ method: AxodMethod<Params, Result>, _ params: Params, timeout: Duration? = nil
  ) async throws -> Result {
    try await rpc.call(method.name.rawValue, params: params, timeout: timeout ?? method.timeout)
  }

  private func call<Result>(_ method: AxodMethod<NoParams, Result>) async throws -> Result {
    try await call(method, nil)
  }
}
