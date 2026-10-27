import AxoProtocol
import Foundation

/// One host, reached through the relay: the same shape as `AxodConnection`, so a client treats
/// "this Mac" and a remote host alike. Calls name the host and the run of it they mean; the
/// relay refuses a call for an older run ("Stale host") instead of acting on the wrong one.
public final class HostConnection: Sendable {
  public let host: RemoteHostRef

  /// What the relay pushes about this host once `subscribe()` has been called. Finishes never;
  /// the relay sends nothing else on this connection that a caller needs.
  public let events: AsyncStream<RemoteHostEvent>

  /// Yields when the connection to the relay ends; events stop until a call (such as
  /// `subscribe()`) connects again.
  public var connectionLost: AsyncStream<Void> { rpc.connectionLost }

  private let rpc: JSONRPCConnection
  private let relayTask: Task<Void, Never>
  private let wantsEvents = EventsWanted()

  /// Whether `subscribe()` has been asked for, so a replacement connection asks again.
  private final class EventsWanted: @unchecked Sendable {
    private let lock = NSLock()
    private var wanted = false
    var value: Bool {
      get { lock.withLock { wanted } }
      set { lock.withLock { wanted = newValue } }
    }
  }

  public init(transport: any AxoTransport, host: RemoteHostRef) {
    self.host = host
    let wantsEvents = wantsEvents
    // The relay keeps what was agreed per connection. A connection opened after the first (the
    // last one dropped or wedged) must agree again and, if events were wanted, ask for them
    // again; otherwise its first call is refused with "Negotiate first".
    let rpc = JSONRPCConnection(transport: transport) { connection in
      let _: ProtocolNegotiation = try await connection.call(
        "axo.protocol.negotiate",
        params: ProtocolNegotiationRequest(protocolVersion: ProtocolNegotiation.supportedVersion),
        timeout: .seconds(10))
      if wantsEvents.value {
        let _: Subscription = try await connection.call("axo.host.subscribe", params: host, timeout: .seconds(10))
      }
    }
    self.rpc = rpc
    let (events, sink) = AsyncStream<RemoteHostEvent>.makeStream(bufferingPolicy: .bufferingNewest(4096))
    self.events = events
    relayTask = Task {
      for await notification in rpc.notifications where notification.method == "axo.host.event" {
        // One connection serves one host, so the host in the event is the filter; an event that
        // does not decode or is for another host is dropped, never delivered.
        guard let params = try? notification.params(as: RemoteHostNotification.self),
          params.event.host == host
        else { continue }
        sink.yield(params.event)
      }
    }
  }

  public convenience init(
    endpoint: RelayEndpoint = .production, host: RemoteHostRef, tokens: any SessionTokenProvider
  ) {
    self.init(
      transport: RelayWebSocketTransport(endpoint: endpoint, host: host, tokens: tokens), host: host)
  }

  deinit { relayTask.cancel() }

  public func disconnect() async {
    await rpc.disconnect()
  }

  // MARK: - Session

  /// Agrees on a protocol version, which the connection already did on opening. Reports what the
  /// host answered.
  public func negotiate() async throws -> ProtocolNegotiation {
    try await call(
      "axo.protocol.negotiate",
      ProtocolNegotiationRequest(protocolVersion: ProtocolNegotiation.supportedVersion))
  }

  /// Starts the host's events: Session snapshots and removals, terminal output, presence.
  public func subscribe() async throws {
    let _: Subscription = try await call("axo.host.subscribe", host)
    wantsEvents.value = true
  }

  /// Connects again after the connection was lost, subscribing again (as every new connection
  /// does once `subscribe()` has been called). Does nothing if a connection is open.
  public func reconnect() async throws {
    try await rpc.connect()
  }

  // MARK: - Workspaces and Sessions

  public func workspaces() async throws -> [RemoteWorkspace] {
    try await call("axo.remote.workspace.list", Target(target: host), as: RemoteWorkspaceList.self)
      .workspaces
  }

  public func createSession() async throws -> RemoteSession {
    try await session(from: call("axo.remote.session.create", Target(target: host)))
  }

  public func createSession(inWorkspace workspaceID: UUID) async throws -> RemoteSession {
    try await session(
      from: call(
        "axo.remote.workspace.session.create",
        WorkspaceTarget(target: host, workspaceId: workspaceID)))
  }

  /// Closes a Session; the host may answer with the replacement it opened if that was the last.
  public func closeSession(_ id: SessionID) async throws -> RemoteSession? {
    let closed: ClosedSession = try await call(
      "axo.remote.session.close", SessionTarget(target: host, sessionId: id))
    guard closed.closed, closed.sessionId == id else {
      throw AxoClientError.invalidResponse("the host did not close that Session")
    }
    return closed.replacement
  }

  public func renameSession(_ id: SessionID, to name: String) async throws {
    try expectSaved(
      await call("axo.remote.session.rename", RenameTarget(target: host, sessionId: id, name: name)))
  }

  public func setLayout(_ layout: SessionLayout, for id: SessionID) async throws {
    try expectSaved(
      await call(
        "axo.remote.session.layout.set", LayoutTarget(target: host, sessionId: id, layout: layout)))
  }

  // MARK: - Terminals

  public func createShell(in id: SessionID) async throws -> ShellID {
    let created: CreatedShell = try await call(
      "axo.remote.shell.create", SessionTarget(target: host, sessionId: id))
    guard created.hostId == host.hostId, created.sessionId == id else {
      throw AxoClientError.invalidResponse("the host created a terminal elsewhere")
    }
    return created.shellId
  }

  public func closeShell(_ shell: ShellID, in id: SessionID) async throws {
    let closed: ClosedShell = try await call(
      "axo.remote.shell.close", ShellTarget(target: host, sessionId: id, shellId: shell))
    guard closed.closed, closed.hostId == host.hostId, closed.sessionId == id,
      closed.shellId == shell
    else { throw AxoClientError.invalidResponse("the host did not close that terminal") }
  }

  /// Sends a prompt to the Session's Pi, as if typed and submitted in its pane. The host refuses it
  /// when the Session has no Pi running.
  public func promptPi(in id: SessionID, text: String) async throws {
    let accepted: PromptAccepted = try await call(
      "axo.remote.session.prompt", PromptTarget(target: host, sessionId: id, text: text))
    guard accepted.accepted else {
      throw AxoClientError.invalidResponse("the host did not accept that prompt")
    }
  }

  /// A key pressed in the Session's Pi, as a person at the Mac would press it.
  public enum PiKey: String, Encodable, Sendable {
    /// Stops the reply in progress, or declines Pi's question.
    case escape
    /// Accepts Pi's question.
    case enter
  }

  /// Presses `key` in the Session's Pi. The host refuses it when the Session has no Pi running.
  public func pressPiKey(_ key: PiKey, in id: SessionID) async throws {
    let accepted: PromptAccepted = try await call(
      "axo.remote.session.key", KeyTarget(target: host, sessionId: id, key: key))
    guard accepted.accepted else {
      throw AxoClientError.invalidResponse("the host did not accept that key")
    }
  }

  /// Types into a terminal. `sequence` numbers this client's input, starting at 0.
  public func sendInput(_ bytes: Data, to shell: ShellID, in id: SessionID, sequence: UInt64)
    async throws
  {
    let accepted: InputAccepted = try await call(
      "axo.remote.terminal.input",
      InputTarget(
        target: host, sessionId: id, shellId: shell, sequence: sequence,
        data: bytes.base64EncodedString()))
    guard accepted.accepted, accepted.sequence == sequence else {
      throw AxoClientError.invalidResponse("the host did not accept that input")
    }
  }

  public func resize(_ shell: ShellID, in id: SessionID, rows: Int, columns: Int) async throws {
    let accepted: ResizeAccepted = try await call(
      "axo.remote.terminal.resize",
      ResizeTarget(target: host, sessionId: id, shellId: shell, rows: rows, columns: columns))
    guard accepted.accepted else {
      throw AxoClientError.invalidResponse("the host did not accept that size")
    }
  }

  // MARK: - Calls

  private func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    _ method: String, _ params: Params, as: Result.Type = Result.self
  ) async throws -> Result {
    try await rpc.call(method, params: params, timeout: .seconds(10))
  }

  private func session(from created: CreatedSession) throws -> RemoteSession {
    guard created.session.hostId == host.hostId else {
      throw AxoClientError.invalidResponse("the host created a Session elsewhere")
    }
    return created.session
  }

  private func expectSaved(_ saved: Saved) throws {
    guard saved.saved else {
      throw AxoClientError.invalidResponse("the host did not save the change")
    }
  }
}

// MARK: - Wire shapes

private struct Target: Encodable, Sendable { let target: RemoteHostRef }
private struct WorkspaceTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let workspaceId: UUID

  private enum CodingKeys: String, CodingKey { case target, workspaceId }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(target, forKey: .target)
    try container.encode(workspaceId.uuidString.lowercased(), forKey: .workspaceId)
  }
}
private struct SessionTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
}
private struct ShellTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let shellId: ShellID
}
private struct RenameTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let name: String
}
private struct PromptTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let text: String
}
private struct KeyTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let key: HostConnection.PiKey
}
private struct LayoutTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let layout: SessionLayout
}
private struct InputTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let shellId: ShellID
  let sequence: UInt64
  let data: String
}
private struct ResizeTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let shellId: ShellID
  let rows: Int
  let columns: Int
}

private struct Subscription: Decodable, Sendable { let subscriptionId: UUID }
private struct CreatedSession: Decodable, Sendable { let session: RemoteSession }
private struct ClosedSession: Decodable, Sendable {
  let closed: Bool
  let sessionId: SessionID
  let replacement: RemoteSession?
}
private struct CreatedShell: Decodable, Sendable {
  let hostId: UUID
  let sessionId: SessionID
  let shellId: ShellID
}
private struct ClosedShell: Decodable, Sendable {
  let closed: Bool
  let hostId: UUID
  let sessionId: SessionID
  let shellId: ShellID
}
private struct Saved: Decodable, Sendable { let saved: Bool }
private struct InputAccepted: Decodable, Sendable {
  let accepted: Bool
  let sequence: UInt64
}
private struct PromptAccepted: Decodable, Sendable { let accepted: Bool }
private struct ResizeAccepted: Decodable, Sendable { let accepted: Bool }
