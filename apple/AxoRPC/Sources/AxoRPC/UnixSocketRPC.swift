import Foundation
import JSONRPC
import Network

struct WorkspaceList: Decodable {
  let workspaces: [WorkspaceRecord]
}

struct ConfigGetRequest: Encodable {
  let key: AxoConfigKey
}

struct ConfigSetRequest: Encodable {
  let key: AxoConfigKey
  let value: String
}

struct WorkspaceCreateRequest: Encodable {
  let name: String
  let directoryPath: String
  let directoryBookmark: String?
}

struct WorkspaceSessionCreateRequest: Encodable {
  let workspaceId: String
}

struct SessionRenameRequest: Encodable {
  let sessionId: SessionID
  let name: String
}

struct WorkspaceRenameRequest: Encodable {
  let workspaceId: String
  let name: String
}

struct WorkspaceArchiveRequest: Encodable {
  let workspaceId: String
}

struct ProtocolNegotiationRequest: Encodable {
  let protocolVersion: UInt32
}

struct RemoteAccessConnectResponse: Decodable {
  let requested: Bool
}

struct ViewportAcknowledgement: Decodable {
  let accepted: Bool
}

struct HostPairingRequest: Encodable {
  let code: String
}

struct CloseTerminalSessionRequest: Encodable {
  let sessionId: SessionID
}

struct RestartPiSessionRequest: Encodable {
  let sessionId: SessionID
  let shellId: ShellID
}

struct CreateTerminalShellRequest: Encodable {
  let sessionId: SessionID
}

struct SetSessionLayoutRequest: Encodable {
  let sessionId: SessionID
  let layout: SessionLayout
}

struct SessionLayoutAcknowledgement: Decodable {
  let saved: Bool
}

/// Identifies one shell; used by `axo.shell.close` and `axo.shell.busy`.
struct ShellRequest: Encodable {
  let sessionId: SessionID
  let shellId: ShellID
}

struct SessionSubscribeRequest: Encodable {
  let sessionId: SessionID?
  let includeTerminalOutput: Bool

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let sessionId { try container.encode(sessionId, forKey: .sessionId) }
    try container.encode(includeTerminalOutput, forKey: .includeTerminalOutput)
  }

  private enum CodingKeys: String, CodingKey { case sessionId, includeTerminalOutput }
}

struct SessionEventsNextRequest: Encodable {
  let subscriptionId: String
  let timeoutMs: UInt64
  let maxEvents: Int
}

struct SessionEventsNextResponse: Decodable {
  let events: [TerminalSessionEvent]
}

struct SessionUnsubscribeRequest: Encodable {
  let subscriptionId: String
}

struct SessionUnsubscribeResponse: Decodable {
  let unsubscribed: Bool
}

/// Wire parameters for methods that take none.
typealias NoParams = String?

/// axod's JSON-RPC method names: the only place they are spelled. Capability checks against
/// `axo.protocol.negotiate`'s method list use these too.
public enum AxodMethodName: String, CaseIterable, Sendable {
  case negotiate = "axo.protocol.negotiate"
  case health = "axo.daemon.health"
  case relayStatus = "axo.relay.status"
  case relayConnect = "axo.relay.connect"
  case relayLink = "axo.relay.link"
  case configGet = "axo.config.get"
  case configSet = "axo.config.set"
  case sessionList = "axo.session.list"
  case sessionCreate = "axo.session.create"
  case sessionClose = "axo.session.close"
  case sessionRename = "axo.session.rename"
  case sessionLayoutSet = "axo.session.layout.set"
  case sessionSubscribe = "axo.session.subscribe"
  case sessionEventsNext = "axo.session.events.next"
  case sessionUnsubscribe = "axo.session.unsubscribe"
  case piRestartForce = "axo.session.pi.restart.force.v2"
  case piRestartAuto = "axo.session.pi.restart.auto.v1"
  case workspaceList = "axo.workspace.list"
  case workspaceCreate = "axo.workspace.create"
  case workspaceRename = "axo.workspace.rename"
  case workspaceArchive = "axo.workspace.archive"
  case workspaceSessionCreate = "axo.workspace.session.create"
  case shellCreate = "axo.shell.create"
  case shellClose = "axo.shell.close"
  case shellBusy = "axo.shell.busy"
  case clientViewportSet = "axo.client.viewport.set"
}

/// One axod JSON-RPC method: its name, parameter and result types, and how long a call may take.
struct AxodMethod<Params: Encodable & Sendable, Result: Decodable & Sendable>: Sendable {
  let name: AxodMethodName
  let timeout: Duration

  init(_ name: AxodMethodName, timeout: Duration = .seconds(5)) {
    self.name = name
    self.timeout = timeout
  }
}

/// axod's methods with their types. `UnixSocketRPC` wraps each with argument shaping and
/// result checks.
enum AxodMethods {
  static let negotiate = AxodMethod<ProtocolNegotiationRequest, ProtocolNegotiation>(.negotiate)
  static let health = AxodMethod<NoParams, DaemonHealth>(.health, timeout: .seconds(2))
  static let relayStatus = AxodMethod<NoParams, RemoteAccessStatus>(.relayStatus)
  static let relayConnect = AxodMethod<NoParams, RemoteAccessConnectResponse>(.relayConnect)
  static let relayLink = AxodMethod<HostPairingRequest, HostPairingResult>(.relayLink)
  static let configGet = AxodMethod<ConfigGetRequest, AxoConfigValue>(.configGet)
  static let configSet = AxodMethod<ConfigSetRequest, AxoConfigValue>(.configSet)
  static let sessionList = AxodMethod<NoParams, TerminalSessionListSnapshot>(.sessionList)
  static let sessionCreate = AxodMethod<NoParams, TerminalSession>(.sessionCreate)
  static let sessionClose = AxodMethod<CloseTerminalSessionRequest, ClosedTerminalSession>(.sessionClose)
  static let sessionRename = AxodMethod<SessionRenameRequest, TerminalSession>(.sessionRename)
  static let sessionLayoutSet = AxodMethod<SetSessionLayoutRequest, SessionLayoutAcknowledgement>(.sessionLayoutSet)
  static let sessionSubscribe = AxodMethod<SessionSubscribeRequest, TerminalSubscriptionID>(.sessionSubscribe)
  static let sessionEventsNext = AxodMethod<SessionEventsNextRequest, SessionEventsNextResponse>(.sessionEventsNext)
  static let sessionUnsubscribe = AxodMethod<SessionUnsubscribeRequest, SessionUnsubscribeResponse>(.sessionUnsubscribe)
  static let piRestartForce = AxodMethod<RestartPiSessionRequest, TerminalSession>(.piRestartForce, timeout: .seconds(20))
  static let piRestartAuto = AxodMethod<RestartPiSessionRequest, TerminalSession>(.piRestartAuto, timeout: .seconds(20))
  static let workspaceList = AxodMethod<NoParams, WorkspaceList>(.workspaceList)
  static let workspaceCreate = AxodMethod<WorkspaceCreateRequest, CreatedWorkspace>(.workspaceCreate)
  static let workspaceRename = AxodMethod<WorkspaceRenameRequest, WorkspaceRecord>(.workspaceRename)
  static let workspaceArchive = AxodMethod<WorkspaceArchiveRequest, ArchivedWorkspace>(.workspaceArchive)
  static let workspaceSessionCreate = AxodMethod<WorkspaceSessionCreateRequest, TerminalSession>(.workspaceSessionCreate)
  static let shellCreate = AxodMethod<CreateTerminalShellRequest, TerminalShell>(.shellCreate)
  static let shellClose = AxodMethod<ShellRequest, ClosedTerminalShell>(.shellClose)
  static let shellBusy = AxodMethod<ShellRequest, TerminalShellBusy>(.shellBusy)
  /// Older daemons do not offer this; check negotiation first.
  static let clientViewportSet = AxodMethod<ClientViewport, ViewportAcknowledgement>(.clientViewportSet)
}

public enum UnixSocketRPC {
  public static let protocolVersion: UInt32 = 1

  public static func negotiate(at socketPath: UnixSocketPath) async throws -> ProtocolNegotiation {
    try await call(AxodMethods.negotiate, ProtocolNegotiationRequest(protocolVersion: protocolVersion), at: socketPath)
  }

  public static func remoteAccessStatus(at socketPath: UnixSocketPath) async throws -> RemoteAccessStatus {
    try await call(AxodMethods.relayStatus, at: socketPath)
  }

  public static func requestRemoteAccessConnection(at socketPath: UnixSocketPath) async throws {
    guard try await call(AxodMethods.relayConnect, at: socketPath).requested else {
      throw UnixSocketRPCError.invalidResponse("axod has no remote relay configured")
    }
  }

  public static func linkHost(
    using code: HostPairingCode,
    at socketPath: UnixSocketPath
  ) async throws -> HostPairingResult {
    let result = try await call(AxodMethods.relayLink, HostPairingRequest(code: code.value), at: socketPath)
    guard result.linked, !result.hostLabel.isEmpty else {
      throw UnixSocketRPCError.invalidResponse("axod did not confirm host pairing")
    }
    return result
  }

  public static func health(at socketPath: UnixSocketPath) async throws -> DaemonHealth {
    let health = try await call(AxodMethods.health, at: socketPath)
    if let version = health.version, version.isEmpty {
      throw UnixSocketRPCError.invalidResponse("daemon version must not be empty")
    }
    guard health.status == "running" else {
      throw UnixSocketRPCError.invalidResponse("daemon status was not running")
    }
    guard BuildNumber(health.buildNumber) != nil else {
      throw UnixSocketRPCError.invalidResponse("build number must be positive")
    }
    return health
  }

  public static func configValue(
    for key: AxoConfigKey,
    at socketPath: UnixSocketPath
  ) async throws -> AxoConfigValue {
    let value = try await call(AxodMethods.configGet, ConfigGetRequest(key: key), at: socketPath)
    guard value.key == key else {
      throw UnixSocketRPCError.invalidResponse("daemon returned configuration for a different key")
    }
    return value
  }

  public static func setConfigValue(
    _ value: String,
    for key: AxoConfigKey,
    at socketPath: UnixSocketPath
  ) async throws -> AxoConfigValue {
    let saved = try await call(
      AxodMethods.configSet, ConfigSetRequest(key: key, value: value), at: socketPath)
    guard saved.key == key else {
      throw UnixSocketRPCError.invalidResponse("daemon saved configuration under a different key")
    }
    return saved
  }

  public static func listSessionSnapshot(
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSessionListSnapshot {
    try await call(AxodMethods.sessionList, at: socketPath)
  }

  public static func listWorkspaces(at socketPath: UnixSocketPath) async throws -> [WorkspaceRecord] {
    try await call(AxodMethods.workspaceList, at: socketPath).workspaces
  }

  public static func createWorkspace(
    name: String,
    directoryPath: String,
    directoryBookmark: String?,
    at socketPath: UnixSocketPath
  ) async throws -> CreatedWorkspace {
    try await call(
      AxodMethods.workspaceCreate,
      WorkspaceCreateRequest(
        name: name, directoryPath: directoryPath, directoryBookmark: directoryBookmark),
      at: socketPath)
  }

  public static func renameSession(
    _ sessionID: SessionID,
    to name: String,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSession {
    try await call(
      AxodMethods.sessionRename, SessionRenameRequest(sessionId: sessionID, name: name), at: socketPath)
  }

  public static func renameWorkspace(
    _ workspaceID: String,
    to name: String,
    at socketPath: UnixSocketPath
  ) async throws -> WorkspaceRecord {
    try await call(
      AxodMethods.workspaceRename, WorkspaceRenameRequest(workspaceId: workspaceID, name: name),
      at: socketPath)
  }

  public static func archiveWorkspace(
    _ workspaceID: String,
    at socketPath: UnixSocketPath
  ) async throws -> ArchivedWorkspace {
    try await call(
      AxodMethods.workspaceArchive, WorkspaceArchiveRequest(workspaceId: workspaceID), at: socketPath)
  }

  public static func createSession(
    in workspaceID: String,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSession {
    try await call(
      AxodMethods.workspaceSessionCreate, WorkspaceSessionCreateRequest(workspaceId: workspaceID),
      at: socketPath)
  }

  /// Opens an event subscription. Catalog consumers pass `includeTerminalOutput: false` to
  /// receive only catalog events (no terminal output or Pi stream events).
  public static func subscribe(
    to sessionID: SessionID? = nil,
    includeTerminalOutput: Bool = true,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSubscriptionID {
    try await call(
      AxodMethods.sessionSubscribe,
      SessionSubscribeRequest(sessionId: sessionID, includeTerminalOutput: includeTerminalOutput),
      at: socketPath)
  }

  /// The daemon's per-poll batch limit.
  public static let maxEventsPerPoll = 256

  /// Waits up to `timeout` for the next event and returns it with any already queued after it,
  /// in order. An empty result means the wait timed out.
  public static func nextEvents(
    for subscription: TerminalSubscriptionID,
    timeout: Duration = .seconds(15),
    maxEvents: Int = maxEventsPerPoll,
    at socketPath: UnixSocketPath
  ) async throws -> [TerminalSessionEvent] {
    let timeoutMilliseconds = min(20_000, max(1, timeout.milliseconds))
    let request = SessionEventsNextRequest(
      subscriptionId: subscription.subscriptionId,
      timeoutMs: UInt64(timeoutMilliseconds),
      maxEvents: min(maxEventsPerPoll, max(1, maxEvents)))
    // The call outlives the server-side wait by a second.
    return try await call(
      AxodMethods.sessionEventsNext, request, at: socketPath,
      timeout: .milliseconds(timeoutMilliseconds + 1_000)
    ).events
  }

  public static func unsubscribe(
    _ subscription: TerminalSubscriptionID,
    at socketPath: UnixSocketPath
  ) async throws {
    let response = try await call(
      AxodMethods.sessionUnsubscribe,
      SessionUnsubscribeRequest(subscriptionId: subscription.subscriptionId), at: socketPath)
    guard response.unsubscribed else {
      throw UnixSocketRPCError.invalidResponse(
        "daemon did not unsubscribe the session event stream")
    }
  }

  public static func createSession(at socketPath: UnixSocketPath) async throws -> TerminalSession {
    try await call(AxodMethods.sessionCreate, at: socketPath)
  }

  public static func closeSession(
    _ sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> ClosedTerminalSession {
    try await call(
      AxodMethods.sessionClose, CloseTerminalSessionRequest(sessionId: sessionID), at: socketPath)
  }

  /// Explicit Restart Pi (`automatically: false`) or the idle-only, non-forcing automatic
  /// recovery (`true`).
  public static func restartPiSession(
    shellID: ShellID,
    in sessionID: SessionID,
    automatically: Bool,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSession {
    try await call(
      automatically ? AxodMethods.piRestartAuto : AxodMethods.piRestartForce,
      RestartPiSessionRequest(sessionId: sessionID, shellId: shellID), at: socketPath)
  }

  public static func createShell(
    in sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalShell {
    try await call(
      AxodMethods.shellCreate, CreateTerminalShellRequest(sessionId: sessionID), at: socketPath)
  }

  public static func setLayout(
    _ layout: SessionLayout,
    for sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws {
    let acknowledgement = try await call(
      AxodMethods.sessionLayoutSet, SetSessionLayoutRequest(sessionId: sessionID, layout: layout),
      at: socketPath)
    guard acknowledgement.saved else {
      throw UnixSocketRPCError.invalidResponse("daemon did not save the session layout")
    }
  }

  public static func closeShell(
    _ shellID: ShellID,
    in sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> ClosedTerminalShell {
    try await call(
      AxodMethods.shellClose, ShellRequest(sessionId: sessionID, shellId: shellID), at: socketPath)
  }

  public static func setViewport(
    _ viewport: ClientViewport,
    at socketPath: UnixSocketPath
  ) async throws {
    guard try await call(AxodMethods.clientViewportSet, viewport, at: socketPath).accepted else {
      throw UnixSocketRPCError.invalidResponse("daemon did not accept the viewport")
    }
  }

  public static func shellBusy(
    _ shellID: ShellID,
    in sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalShellBusy {
    try await call(
      AxodMethods.shellBusy, ShellRequest(sessionId: sessionID, shellId: shellID), at: socketPath)
  }

  /// Calls `method` on a fresh connection, within its timeout unless `timeout` overrides it.
  private static func call<Params, Result>(
    _ method: AxodMethod<Params, Result>,
    _ params: Params,
    at socketPath: UnixSocketPath,
    timeout: Duration? = nil
  ) async throws -> Result {
    try await withResponse(at: socketPath, timeout: timeout ?? method.timeout) { session in
      try await session.response(to: method.name.rawValue, params: params)
    }
  }

  private static func call<Result>(
    _ method: AxodMethod<NoParams, Result>,
    at socketPath: UnixSocketPath
  ) async throws -> Result {
    try await call(method, nil, at: socketPath)
  }

  private static func withResponse<Response: Decodable>(
    at socketPath: UnixSocketPath,
    timeout: Duration = .seconds(5),
    request: @escaping @Sendable (JSONRPCSession) async throws -> Response
  ) async throws -> Response {
    let transport = UnixSocketTransport(socketPath: socketPath)
    try await transport.connect()
    defer { transport.close() }

    let session = JSONRPCSession(channel: transport.dataChannel)
    do {
      return try await withThrowingTaskGroup(of: Response.self) { group in
        group.addTask {
          try await request(session)
        }
        group.addTask {
          try await Task.sleep(nanoseconds: timeout.nanoseconds)
          transport.close()
          throw UnixSocketRPCError.requestTimedOut
        }
        defer { group.cancelAll() }
        guard let response = try await group.next() else {
          throw UnixSocketRPCError.requestTimedOut
        }
        return response
      }
    } catch let error as JSONRPC.AnyJSONRPCResponseError {
      throw UnixSocketRPCError.serverRejected(code: error.code, message: error.message)
    }
  }
}
