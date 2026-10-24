import Foundation
import JSONRPC
import Network

private struct WorkspaceList: Decodable {
  let workspaces: [WorkspaceRecord]
}

private struct ConfigGetRequest: Encodable {
  let key: AxoConfigKey
}

private struct ConfigSetRequest: Encodable {
  let key: AxoConfigKey
  let value: String
}

private struct WorkspaceCreateRequest: Encodable {
  let name: String
  let directoryPath: String
  let directoryBookmark: String?
}

private struct WorkspaceSessionCreateRequest: Encodable {
  let workspaceId: String
}

private struct SessionRenameRequest: Encodable {
  let sessionId: SessionID
  let name: String
}

private struct WorkspaceRenameRequest: Encodable {
  let workspaceId: String
  let name: String
}

private struct WorkspaceArchiveRequest: Encodable {
  let workspaceId: String
}

private struct ProtocolNegotiationRequest: Encodable {
  let protocolVersion: UInt32
}

private struct RemoteAccessDisabled: Decodable {
  let disabled: Bool
}

private struct RemoteAccessConnectResponse: Decodable {
  let requested: Bool
}

private struct HostPairingRequest: Encodable {
  let code: String
}

private struct CloseTerminalSessionRequest: Encodable {
  let sessionId: SessionID
}

private struct RestartPiSessionRequest: Encodable {
  let sessionId: SessionID
  let shellId: ShellID
}

private struct CreateTerminalShellRequest: Encodable {
  let sessionId: SessionID
}

private struct SetSessionLayoutRequest: Encodable {
  let sessionId: SessionID
  let layout: SessionLayout
}

private struct SessionLayoutAcknowledgement: Decodable {
  let saved: Bool
}

private struct CloseTerminalShellRequest: Encodable {
  let sessionId: SessionID
  let shellId: ShellID
}

private struct SessionSubscribeRequest: Encodable {
  let sessionId: SessionID?
  let includeTerminalOutput: Bool

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let sessionId { try container.encode(sessionId, forKey: .sessionId) }
    try container.encode(includeTerminalOutput, forKey: .includeTerminalOutput)
  }

  private enum CodingKeys: String, CodingKey { case sessionId, includeTerminalOutput }
}

private struct SessionEventsNextRequest: Encodable {
  let subscriptionId: String
  let timeoutMs: UInt64
}

private struct SessionEventsNextResponse: Decodable {
  let event: TerminalSessionEvent?
}

private struct SessionUnsubscribeRequest: Encodable {
  let subscriptionId: String
}

private struct SessionUnsubscribeResponse: Decodable {
  let unsubscribed: Bool
}

public enum UnixSocketRPC {
  public static let protocolVersion: UInt32 = 1

  public static func negotiate(at socketPath: UnixSocketPath) async throws -> ProtocolNegotiation {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.protocol.negotiate",
        params: ProtocolNegotiationRequest(protocolVersion: Self.protocolVersion)
      )
    }
  }

  public static func remoteAccessSettings(
    at socketPath: UnixSocketPath
  ) async throws -> RemoteAccessSettings {
    try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.relay.settings")
    }
  }

  public static func remoteAccessStatus(
    at socketPath: UnixSocketPath
  ) async throws -> RemoteAccessStatus {
    try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.relay.status")
    }
  }

  public static func requestRemoteAccessConnection(
    at socketPath: UnixSocketPath
  ) async throws {
    let response: RemoteAccessConnectResponse = try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.relay.connect")
    }
    guard response.requested else {
      throw UnixSocketRPCError.invalidResponse("axod has no remote relay configured")
    }
  }

  public static func linkHost(
    using code: HostPairingCode,
    at socketPath: UnixSocketPath
  ) async throws -> HostPairingResult {
    let result: HostPairingResult = try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.relay.link",
        params: HostPairingRequest(code: code.value)
      )
    }
    guard result.linked, !result.hostLabel.isEmpty else {
      throw UnixSocketRPCError.invalidResponse("axod did not confirm host pairing")
    }
    return result
  }

  public static func configureRemoteAccess(
    _ configuration: RemoteAccessConfiguration,
    at socketPath: UnixSocketPath
  ) async throws -> RemoteAccessSettings {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.relay.configure",
        params: configuration
      )
    }
  }

  public static func disableRemoteAccess(at socketPath: UnixSocketPath) async throws {
    let response: RemoteAccessDisabled = try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.relay.disable")
    }
    guard response.disabled else {
      throw UnixSocketRPCError.invalidResponse("daemon did not disable remote access")
    }
  }

  public static func health(at socketPath: UnixSocketPath) async throws -> DaemonHealth {
    let health: DaemonHealth = try await withResponse(
      at: socketPath,
      timeout: .seconds(2)
    ) { session in
      try await session.response(to: "axo.daemon.health")
    }
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
    let value: AxoConfigValue = try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.config.get",
        params: ConfigGetRequest(key: key)
      )
    }
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
    let saved: AxoConfigValue = try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.config.set",
        params: ConfigSetRequest(key: key, value: value)
      )
    }
    guard saved.key == key else {
      throw UnixSocketRPCError.invalidResponse("daemon saved configuration under a different key")
    }
    return saved
  }

  public static func listSessions(at socketPath: UnixSocketPath) async throws -> [TerminalSession] {
    let snapshot = try await listSessionSnapshot(at: socketPath)
    return snapshot.sessions
  }

  public static func listSessionSnapshot(
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSessionListSnapshot {
    try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.session.list")
    }
  }

  public static func listWorkspaces(at socketPath: UnixSocketPath) async throws -> [WorkspaceRecord] {
    let response: WorkspaceList = try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.workspace.list")
    }
    return response.workspaces
  }

  public static func createWorkspace(
    name: String,
    directoryPath: String,
    directoryBookmark: String?,
    at socketPath: UnixSocketPath
  ) async throws -> CreatedWorkspace {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.workspace.create",
        params: WorkspaceCreateRequest(
          name: name,
          directoryPath: directoryPath,
          directoryBookmark: directoryBookmark
        )
      )
    }
  }

  public static func renameSession(
    _ sessionID: SessionID,
    to name: String,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSession {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.session.rename",
        params: SessionRenameRequest(sessionId: sessionID, name: name)
      )
    }
  }

  public static func renameWorkspace(
    _ workspaceID: String,
    to name: String,
    at socketPath: UnixSocketPath
  ) async throws -> WorkspaceRecord {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.workspace.rename",
        params: WorkspaceRenameRequest(workspaceId: workspaceID, name: name)
      )
    }
  }

  public static func archiveWorkspace(
    _ workspaceID: String,
    at socketPath: UnixSocketPath
  ) async throws -> ArchivedWorkspace {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.workspace.archive",
        params: WorkspaceArchiveRequest(workspaceId: workspaceID)
      )
    }
  }

  public static func createSession(
    in workspaceID: String,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSession {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.workspace.session.create",
        params: WorkspaceSessionCreateRequest(workspaceId: workspaceID))
    }
  }

  /// Opens an event subscription. Catalog consumers pass `includeTerminalOutput: false`.
  public static func subscribe(
    to sessionID: SessionID? = nil,
    includeTerminalOutput: Bool = true,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSubscriptionID {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.session.subscribe",
        params: SessionSubscribeRequest(
          sessionId: sessionID, includeTerminalOutput: includeTerminalOutput))
    }
  }

  public static func nextEvent(
    for subscription: TerminalSubscriptionID,
    timeout: Duration = .seconds(15),
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSessionEvent? {
    let timeoutMilliseconds = min(20_000, max(1, timeout.milliseconds))
    let response: SessionEventsNextResponse = try await withResponse(
      at: socketPath,
      timeout: .milliseconds(timeoutMilliseconds + 1_000)
    ) { session in
      try await session.response(
        to: "axo.session.events.next",
        params: SessionEventsNextRequest(
          subscriptionId: subscription.subscriptionId,
          timeoutMs: UInt64(timeoutMilliseconds)))
    }
    return response.event
  }

  public static func unsubscribe(
    _ subscription: TerminalSubscriptionID,
    at socketPath: UnixSocketPath
  ) async throws {
    let response: SessionUnsubscribeResponse = try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.session.unsubscribe",
        params: SessionUnsubscribeRequest(subscriptionId: subscription.subscriptionId))
    }
    guard response.unsubscribed else {
      throw UnixSocketRPCError.invalidResponse(
        "daemon did not unsubscribe the session event stream")
    }
  }



  public static func createSession(at socketPath: UnixSocketPath) async throws -> TerminalSession {
    try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.session.create")
    }
  }

  public static func closeSession(
    _ sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> ClosedTerminalSession {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.session.close",
        params: CloseTerminalSessionRequest(sessionId: sessionID)
      )
    }
  }

  public static func restartPiSession(
    shellID: ShellID,
    in sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSession {
    try await withResponse(at: socketPath, timeout: .seconds(20)) { session in
      try await session.response(
        to: "axo.session.pi.restart.force.v2",
        params: RestartPiSessionRequest(sessionId: sessionID, shellId: shellID)
      )
    }
  }

  public static func automaticallyRestartPiSession(
    shellID: ShellID,
    in sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSession {
    try await withResponse(at: socketPath, timeout: .seconds(20)) { session in
      try await session.response(
        to: "axo.session.pi.restart.auto.v1",
        params: RestartPiSessionRequest(sessionId: sessionID, shellId: shellID)
      )
    }
  }

  public static func createShell(
    in sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalShell {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.shell.create",
        params: CreateTerminalShellRequest(sessionId: sessionID)
      )
    }
  }

  public static func setLayout(
    _ layout: SessionLayout,
    for sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws {
    let acknowledgement: SessionLayoutAcknowledgement = try await withResponse(
      at: socketPath
    ) { session in
      try await session.response(
        to: "axo.session.layout.set",
        params: SetSessionLayoutRequest(sessionId: sessionID, layout: layout)
      )
    }
    guard acknowledgement.saved else {
      throw UnixSocketRPCError.invalidResponse("daemon did not save the session layout")
    }
  }

  public static func closeShell(
    _ shellID: ShellID,
    in sessionID: SessionID,
    at socketPath: UnixSocketPath
  ) async throws -> ClosedTerminalShell {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.shell.close",
        params: CloseTerminalShellRequest(sessionId: sessionID, shellId: shellID)
      )
    }
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
