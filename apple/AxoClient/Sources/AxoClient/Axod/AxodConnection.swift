import AxoProtocol
import Foundation

/// axod's local API over any transport, on one persistent connection.
///
/// Each method shapes its arguments and checks what the host returned beyond decoding (a result
/// for the key or Session asked about, an acknowledgement that is actually positive), so callers
/// only see well-formed answers or an `AxoClientError`.
public final class AxodConnection: Sendable {
  private let rpc: JSONRPCConnection
  private let transport: any AxoTransport

  public init(transport: any AxoTransport) {
    self.transport = transport
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

  // MARK: - Asking the person (RFD0029)

  /// What waits for the person on this Mac, oldest first.
  public func pendingElicitations() async throws -> [Elicitation] {
    try await call(AxodMethods.elicitationList).elicitations
  }

  /// The person's answer, from this app. axod takes it only from Axo.app, by code signature;
  /// a question answered already fails with `ElicitationError.notPending`.
  /// An input request's `values` go in the clear: this socket is axod's own, and it takes answers
  /// on it only from Axo.app.
  public func resolveElicitation(_ id: String, action: ElicitationAnswer, values: [String: String]? = nil) async throws {
    let result = try await call(
      AxodMethods.elicitationResolve, LocalElicitationAnswer(elicitationId: id, action: action, values: values))
    guard result.resolved else {
      throw AxoClientError.invalidResponse("axod did not take the answer")
    }
  }

  // MARK: - Sessions

  public func listSessionSnapshot() async throws -> TerminalSessionListSnapshot {
    try await call(AxodMethods.sessionList)
  }

  /// A new Session at home (RFD0038).
  public func createSession() async throws -> TerminalSession {
    try await call(AxodMethods.sessionCreate, SessionCreateRequest(folder: nil, like: nil))
  }

  /// A new Session in `folder`, an absolute path to a directory that exists.
  public func createSession(inFolder folder: String) async throws -> TerminalSession {
    try await call(AxodMethods.sessionCreate, SessionCreateRequest(folder: folder, like: nil))
  }

  /// A new Session in the folder of the open Session `sessionID`.
  public func createSession(like sessionID: SessionID) async throws -> TerminalSession {
    try await call(AxodMethods.sessionCreate, SessionCreateRequest(folder: nil, like: sessionID))
  }

  public func closeSession(_ sessionID: SessionID) async throws -> ClosedTerminalSession {
    try await call(AxodMethods.sessionClose, CloseTerminalSessionRequest(sessionId: sessionID))
  }

  /// The other Macs' Sessions, as this Mac follows them (RFD0024).
  public func listPeerSessions() async throws -> PeerSessionList {
    try await call(AxodMethods.peerSessionsList)
  }

  /// Opens a pane on another Mac's Session here, or returns the one already open.
  public func openPeerSession(_ sessionID: SessionID, on hostID: String) async throws -> PeerSession {
    try await call(AxodMethods.peerSessionOpen, PeerSessionRequest(hostId: hostID, sessionId: sessionID))
  }

  /// Stops this Mac's pane on another Mac's Session; the Session itself carries on there.
  public func closePeerSession(_ sessionID: SessionID, on hostID: String) async throws {
    _ = try await call(AxodMethods.peerSessionClose, PeerSessionRequest(hostId: hostID, sessionId: sessionID))
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

  /// Opens a stream of events on a connection of its own: axod pushes each batch the moment
  /// there is one, so nothing is polled. Catalog consumers pass `includeTerminalOutput: false`.
  public func openEventStream(to sessionID: SessionID?, includeTerminalOutput: Bool) async throws
    -> AxodEventStream
  {
    try await AxodEventStream.open(
      transport: transport,
      request: SessionSubscribeRequest(
        sessionId: sessionID, includeTerminalOutput: includeTerminalOutput))
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
