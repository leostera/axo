import AxoProtocol
import Foundation

/// The account's client (RFD0018): one socket to this client's ClientDO, which follows every
/// host of the account. It lists the hosts and Sessions and keeps them current, serves the records
/// of the Sessions the app opens (the next batch comes once the last is acknowledged), and carries
/// commands to hosts.
///
/// Every new connection says hello first and yields `.hello` with the whole listing, so a client
/// that lost its connection learns everything it missed from that one event.
public final class AccountConnection: Sendable {
  /// What the socket says as it happens. Finishes never.
  public let events: AsyncStream<AccountEvent>

  /// Yields when the connection ends; events stop until `connect()` connects again.
  public var connectionLost: AsyncStream<Void> { rpc.connectionLost }

  private let rpc: JSONRPCConnection
  private let relayTask: Task<Void, Never>

  public init(transport: any AxoTransport, clientID: ClientID) {
    let (events, sink) = AsyncStream<AccountEvent>.makeStream(bufferingPolicy: .bufferingNewest(4096))
    self.events = events
    let rpc = JSONRPCConnection(transport: transport) { connection in
      let hello: ClientHello = try await connection.call(
        "axo.client.hello", params: Hello(protocolVersion: ProtocolNegotiation.supportedVersion, clientId: clientID.rawValue),
        timeout: .seconds(10))
      sink.yield(.hello(hello))
    }
    self.rpc = rpc
    relayTask = Task {
      for await notification in rpc.notifications {
        // A notice that does not decode is dropped, never guessed at.
        if let event = Self.event(from: notification) { sink.yield(event) }
      }
    }
  }

  public convenience init(endpoint: RelayEndpoint = .production, clientID: ClientID, tokens: any SessionTokenProvider) {
    self.init(transport: RelayWebSocketTransport(endpoint: endpoint, clientID: clientID, tokens: tokens), clientID: clientID)
  }

  deinit { relayTask.cancel() }

  /// Connects and says hello, if not connected. Does nothing if a connection is open.
  public func connect() async throws {
    try await rpc.connect()
  }

  public func disconnect() async {
    await rpc.disconnect()
  }

  /// Lists the account's hosts and Sessions again now: for a Mac paired a moment ago.
  public func refresh() async throws -> ClientHello {
    try await rpc.call("axo.client.refresh", params: Empty(), timeout: .seconds(10))
  }

  /// Opens a Session: the records after `have`, or else its last `window`. Newer records follow
  /// as `.records` events.
  public func open(_ session: SessionID, on host: UUID, have: (epoch: Int64, cursor: Int64)? = nil, window: Int = 50)
    async throws -> ClientOpenResult
  {
    try await rpc.call(
      "axo.client.session.open",
      params: OpenParams(
        hostId: host.uuidString.lowercased(), sessionId: session,
        have: have.map { OpenParams.Have(epoch: $0.epoch, cursor: $0.cursor) },
        window: have == nil ? OpenParams.Window(last: min(max(window, 1), 64)) : nil),
      timeout: .seconds(10))
  }

  /// Records just before `before`, oldest first.
  public func older(_ session: SessionID, before: Int64, limit: Int = 50) async throws -> ClientOlderPage {
    try await rpc.call(
      "axo.client.session.older", params: OlderParams(sessionId: session, before: before, limit: min(max(limit, 1), 64)),
      timeout: .seconds(10))
  }

  /// Says the records up to `cursor` were taken: the next batch may come.
  public func acknowledge(_ session: SessionID, cursor: Int64) async {
    await rpc.notify("axo.client.session.ack", params: AckParams(sessionId: session, cursor: cursor))
  }

  /// Stops following a Session's records.
  public func close(_ session: SessionID) async {
    await rpc.notify("axo.client.session.close", params: CloseParams(sessionId: session))
  }

  /// Runs `method` on a host. It fails at once when the host is offline (-32005); nothing is
  /// queued.
  public func command<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    _ method: String, on host: UUID, params: Params, as: Result.Type = Result.self
  ) async throws -> Result {
    try await rpc.call(
      "axo.client.command", params: CommandParams(hostId: host.uuidString.lowercased(), method: method, params: params),
      timeout: .seconds(10))
  }

  // MARK: - Notices

  private static func event(from notification: JSONRPCNotification) -> AccountEvent? {
    switch notification.method {
    case "axo.client.hosts":
      return (try? notification.params(as: HostsNotice.self)).map { .hosts($0.hosts) }
    case "axo.client.sessions":
      return (try? notification.params(as: SessionsNotice.self)).map { .sessions(hostID: $0.hostId, $0.sessions) }
    case "axo.client.session.records":
      return (try? notification.params(as: RecordsNotice.self)).map {
        .records(sessionID: $0.sessionId, epoch: $0.epoch, $0.records, cursor: $0.cursor)
      }
    case "axo.client.session.progress":
      return (try? notification.params(as: ProgressNotice.self)).map {
        .progress(sessionID: $0.sessionId, slot: $0.slot, snapshot: $0.snapshot ?? .null)
      }
    case "axo.client.session.reset":
      return (try? notification.params(as: ResetNotice.self)).map { .reset(sessionID: $0.sessionId, epoch: $0.epoch, keep: $0.keep) }
    default:
      return nil
    }
  }
}

// MARK: - Wire shapes

private struct Empty: Codable, Sendable {}
private struct Hello: Encodable, Sendable {
  let protocolVersion: UInt32
  let clientId: String
}
private struct OpenParams: Encodable, Sendable {
  struct Have: Encodable, Sendable {
    let epoch: Int64
    let cursor: Int64
  }
  struct Window: Encodable, Sendable { let last: Int }
  let hostId: String
  let sessionId: SessionID
  let have: Have?
  let window: Window?
}
private struct OlderParams: Encodable, Sendable {
  let sessionId: SessionID
  let before: Int64
  let limit: Int
}
private struct AckParams: Encodable, Sendable {
  let sessionId: SessionID
  let cursor: Int64
}
private struct CloseParams: Encodable, Sendable { let sessionId: SessionID }
private struct CommandParams<Params: Encodable & Sendable>: Encodable, Sendable {
  let hostId: String
  let method: String
  let params: Params
}
private struct HostsNotice: Decodable { let hosts: [ClientHost] }
private struct SessionsNotice: Decodable {
  let hostId: UUID
  let sessions: [ClientSession]
}
private struct RecordsNotice: Decodable {
  let sessionId: SessionID
  let epoch: Int64
  let records: [ClientRecord]
  let cursor: Int64
}
private struct ProgressNotice: Decodable {
  let sessionId: SessionID
  let slot: String
  let snapshot: JSONValue?
}
private struct ResetNotice: Decodable {
  let sessionId: SessionID
  let epoch: Int64
  let keep: Int64
}
