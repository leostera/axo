import AxoProtocol
import Foundation

/// The account's client (RFD0018, RFD0032).
///
/// In protocol 3 the account's socket lists the hosts, and a socket on each host's HostDO carries
/// that host's Sessions, records, commands and questions: a record reaches the app straight from
/// the append, and a reconnect costs one hello per host. When the cloud refuses protocol 3, the
/// connection falls back to protocol 2, where one socket to this client's ClientDO carries
/// everything, and tries 3 again ten minutes later. The events and calls are the same either way.
///
/// Every new connection says hello first and yields `.hello` with the whole listing, so a client
/// that lost its connection learns everything it missed from that one event. Any of its sockets
/// ending ends the connection: `connectionLost` yields, and `connect()` starts afresh.
public final class AccountConnection: Sendable {
  /// What the sockets say as it happens. Finishes never.
  public let events: AsyncStream<AccountEvent>

  /// Yields when the connection ends; events stop until `connect()` connects again.
  public let connectionLost: AsyncStream<Void>

  private let rpc: JSONRPCConnection
  private let router: Router
  private let tasks: [Task<Void, Never>]

  /// `hosts` opens a socket on a host's HostDO; without it the connection speaks protocol 2 only.
  public init(transport: any AxoTransport, clientID: ClientID, hosts: (@Sendable (UUID) -> any AxoTransport)? = nil) {
    let (events, sink) = AsyncStream<AccountEvent>.makeStream(bufferingPolicy: .bufferingNewest(4096))
    let (lost, lossSink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.events = events
    connectionLost = lost
    let (ends, endSink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let router = Router(clientID: clientID, hosts: hosts, events: sink, endConnection: endSink)
    self.router = router
    let rpc = JSONRPCConnection(transport: transport) { connection in
      try await router.hello(on: connection)
    }
    self.rpc = rpc
    tasks = [
      Task {
        for await notification in rpc.notifications { await router.receive(notification, from: nil) }
      },
      Task {
        for await _ in rpc.connectionLost {
          await router.letGo()
          lossSink.yield()
        }
      },
      // A host's socket ending ends the connection: the account's goes, and with it the rest.
      Task {
        for await _ in ends { await rpc.disconnect() }
      },
    ]
  }

  public convenience init(endpoint: RelayEndpoint = .production, clientID: ClientID, tokens: any SessionTokenProvider,
    transport: AccountTransportMode = .platformDefault
  ) {
    switch transport {
    case .https:
      // One protocol-2 account connection, carried entirely over high-level HTTPS on watchOS.
      self.init(transport: RelayHTTPTransport(endpoint: endpoint, clientID: clientID, tokens: tokens), clientID: clientID)
    case .webSocket:
      self.init(
        transport: RelayWebSocketTransport(endpoint: endpoint, clientID: clientID, tokens: tokens), clientID: clientID,
        hosts: { host in
          RelayWebSocketTransport(
            endpoint: endpoint, clientID: clientID, tokens: tokens, url: endpoint.hostClientSocketURL(host: host, clientID: clientID))
        })
    }
  }

  deinit { for task in tasks { task.cancel() } }

  /// Connects and says hello, if not connected. Does nothing if a connection is open.
  public func connect() async throws {
    try await withFallback { try await rpc.connect() }
  }

  public func disconnect() async {
    await rpc.disconnect()
  }

  /// Lists the account's hosts and Sessions again now: for a Mac paired a moment ago.
  public func refresh() async throws -> ClientHello {
    let listing: ClientHello = try await withFallback {
      try await rpc.call("axo.client.refresh", params: Empty(), timeout: .seconds(10))
    }
    return try await router.refreshed(listing)
  }

  /// Opens a Session: the records after `have`, or else its last `window`. Newer records follow
  /// as `.records` events.
  public func open(_ session: SessionID, on host: UUID, have: (epoch: Int64, cursor: Int64)? = nil, window: Int = 50)
    async throws -> ClientOpenResult
  {
    try await connection(for: host, opening: session).call(
      "axo.client.session.open",
      params: OpenParams(
        hostId: host.uuidString.lowercased(), sessionId: session,
        have: have.map { OpenParams.Have(epoch: $0.epoch, cursor: $0.cursor) },
        window: have == nil ? OpenParams.Window(last: min(max(window, 1), 64)) : nil),
      timeout: .seconds(10))
  }

  /// Records just before `before`, oldest first.
  public func older(_ session: SessionID, before: Int64, limit: Int = 50) async throws -> ClientOlderPage {
    try await connection(of: session).call(
      "axo.client.session.older", params: OlderParams(sessionId: session, before: before, limit: min(max(limit, 1), 64)),
      timeout: .seconds(10))
  }

  /// Says the records up to `cursor` were taken: the next batch may come.
  public func acknowledge(_ session: SessionID, cursor: Int64) async {
    guard let connection = try? await connection(of: session) else { return }
    await connection.notify("axo.client.session.ack", params: AckParams(sessionId: session, cursor: cursor))
  }

  /// Stops following a Session's records.
  public func close(_ session: SessionID) async {
    guard let connection = try? await connection(of: session) else { return }
    await router.closed(session)
    await connection.notify("axo.client.session.close", params: CloseParams(sessionId: session))
  }

  /// Names a Mac for the whole account: every client shows the name at once, and the Mac keeps it
  /// across reapps. An empty name goes back to the Mac's own. Returns the name it now has.
  public func renameHost(_ host: UUID, to name: String) async throws -> String {
    let renamed: HostRenamed = try await withFallback {
      try await rpc.call(
        "axo.client.host.rename", params: RenameHostParams(hostId: host.uuidString.lowercased(), name: name),
        timeout: .seconds(10))
    }
    return renamed.label
  }

  /// Runs `method` on a host. It fails at once when the host is offline (-32005); nothing is
  /// queued.
  public func command<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    _ method: String, on host: UUID, params: Params, as: Result.Type = Result.self
  ) async throws -> Result {
    try await connection(for: host).call(
      "axo.client.command", params: CommandParams(hostId: host.uuidString.lowercased(), method: method, params: params),
      timeout: .seconds(10))
  }

  /// Answers what a Mac's agent asks (RFD0029). The Mac takes the first answer; a later one
  /// fails with `ElicitationError.notPending`.
  /// An accepted input request's values go `sealed` to the Mac: the cloud never reads them.
  /// `device` is this device's signature over the answer: the Mac takes answers only from devices
  /// allowed in Axo there.
  public func resolveElicitation(
    _ id: String, on host: UUID, action: ElicitationAnswer, device: DeviceProof, sealed: SealedInput? = nil
  ) async throws {
    let _: Resolved = try await connection(for: host).call(
      "axo.elicitation.resolve",
      params: ResolveParams(
        hostId: host.uuidString.lowercased(), elicitationId: id, action: action, sealed: sealed, device: device),
      timeout: .seconds(20))
  }

  // MARK: - Routing

  /// Runs `body`, again once if the cloud just refused protocol 3: the next connection speaks 2.
  private func withFallback<Value>(_ body: () async throws -> Value) async throws -> Value {
    do {
      return try await body()
    } catch Router.Refused.protocol3 {
      return try await body()
    }
  }

  /// The connection that serves `host`, connected: its HostDO's in protocol 3, else the account's.
  private func connection(for host: UUID, opening session: SessionID? = nil) async throws -> JSONRPCConnection {
    try await connect()
    return try await router.connection(for: host, opening: session) ?? rpc
  }

  /// The connection a Session was opened on.
  private func connection(of session: SessionID) async throws -> JSONRPCConnection {
    try await router.connection(of: session) ?? rpc
  }
}

/// Which protocol the connection speaks, the sockets on each host in protocol 3, and what each
/// host said last. A connection's host sockets live and end with it: one that ends ends them all.
private actor Router {
  enum Refused: Error { case protocol3 }

  /// Which protocol this connection speaks (RFD0032).
  enum Spoken {
    /// Everything on the account's socket, through the ClientDO.
    case relayed
    /// The account's socket lists the hosts; each host's HostDO serves its own Sessions.
    case direct
  }

  /// How long a refused protocol 3 stays refused before it is tried again.
  static let relayedAfterRefusal: Duration = .seconds(10 * 60)

  private struct Link {
    let rpc: JSONRPCConnection
    var online = false
    var hostGeneration: UUID?
    var sessions: [SessionID: ClientSession] = [:]
    var tasks: [Task<Void, Never>] = []
  }

  private let clientID: ClientID
  private let hosts: (@Sendable (UUID) -> any AxoTransport)?
  private let sink: AsyncStream<AccountEvent>.Continuation
  /// Asks for the whole connection to end.
  private let endConnection: AsyncStream<Void>.Continuation
  private var relayedUntil: ContinuousClock.Instant?
  private var spoken = Spoken.relayed
  /// Whether this connection's `.hello` went out: questions asked before it wait for it.
  private var listed = false
  private var held: [AccountEvent] = []
  private var accountHosts: [ClientHost] = []
  /// What the account's socket listed at hello, in protocol 2.
  private var relayedListing = ClientHello(hosts: [], sessions: [])
  private var links: [UUID: Link] = [:]
  private var opened: [SessionID: UUID] = [:]
  private var lastConnection: UInt64 = 0

  init(
    clientID: ClientID, hosts: (@Sendable (UUID) -> any AxoTransport)?, events: AsyncStream<AccountEvent>.Continuation,
    endConnection: AsyncStream<Void>.Continuation
  ) {
    self.clientID = clientID
    self.hosts = hosts
    sink = events
    self.endConnection = endConnection
  }

  /// Says hello on a new account socket, and in protocol 3 on every host's.
  func hello(on connection: JSONRPCConnection.LinkCaller) async throws {
    letGo()
    let refusedLately = relayedUntil.map { ContinuousClock.now < $0 } ?? false
    if hosts == nil || refusedLately {
      try await helloRelayed(on: connection)
    } else {
      try await helloDirect(on: connection)
    }
    listed = true
    sink.yield(.hello(listing()))
    for event in held { sink.yield(event) }
    held = []
  }

  private func helloRelayed(on connection: JSONRPCConnection.LinkCaller) async throws {
    spoken = .relayed
    let hello: ClientHello = try await connection.call(
      "axo.client.hello", params: Hello(protocolVersion: 2, clientId: clientID.rawValue), timeout: .seconds(10))
    relayedListing = hello
  }

  /// Protocol 3. Refused when the account's socket refuses hello 3 (it runs older code), or when
  /// a host's socket fails before its index comes (that host may too): the next connection then
  /// speaks 2 for a while. Any other failure fails this connection only.
  private func helloDirect(on connection: JSONRPCConnection.LinkCaller) async throws {
    spoken = .direct
    let hello: ClientHello
    do {
      hello = try await connection.call(
        "axo.client.hello", params: Hello(protocolVersion: 3, clientId: clientID.rawValue), timeout: .seconds(10))
    } catch AxoClientError.serverRejected(let code, _) where code == -32602 {
      throw refuseDirect()
    }
    accountHosts = hello.hosts
    let number = nextConnection()
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for host in hello.hosts {
          let rpc = link(host.hostId, connection: number)
          group.addTask { try await rpc.connect() }
        }
        try await group.waitForAll()
      }
    } catch {
      throw refuseDirect()
    }
  }

  private func refuseDirect() -> Refused {
    letGo()
    relayedUntil = ContinuousClock.now + Self.relayedAfterRefusal
    return .protocol3
  }

  /// The connection ended, or a new one starts: every host socket goes with it.
  func letGo() {
    for link in links.values {
      for task in link.tasks { task.cancel() }
      let rpc = link.rpc
      Task { await rpc.disconnect() }
    }
    links = [:]
    opened = [:]
    listed = false
    held = []
  }

  func connection(for host: UUID, opening session: SessionID?) throws -> JSONRPCConnection? {
    guard spoken == .direct else { return nil }
    // Nothing went anywhere: the same answer the ClientDO gives for a host it can't reach.
    guard let link = links[host] else {
      throw AxoClientError.serverRejected(code: -32005, message: "Host offline; nothing queued")
    }
    if let session { opened[session] = host }
    return link.rpc
  }

  func connection(of session: SessionID) throws -> JSONRPCConnection? {
    guard spoken == .direct else { return nil }
    guard let host = opened[session], let link = links[host] else { throw AxoClientError.connectionClosed }
    return link.rpc
  }

  func closed(_ session: SessionID) { opened[session] = nil }

  /// What `axo.client.refresh` answered, as the app sees it: in protocol 3, with each host's
  /// presence and Sessions, once a newly listed host's socket is open.
  func refreshed(_ listing: ClientHello) async throws -> ClientHello {
    guard spoken == .direct else { return listing }
    accountHosts = listing.hosts
    try await follow()
    return self.listing()
  }

  // MARK: - Notices

  /// A notice from the account's socket (`host` nil) or a host's.
  func receive(_ notification: JSONRPCNotification, from host: UUID?) async {
    switch notification.method {
    case "axo.client.hosts":
      guard let hosts = try? notification.params(as: HostsNotice.self).hosts else { return }
      guard spoken == .direct else {
        sink.yield(.hosts(hosts))
        return
      }
      guard host == nil else { return }
      accountHosts = hosts
      if (try? await follow()) != nil { sink.yield(.hosts(self.hostList())) }
    case "axo.client.host.presence":
      guard let host, let presence = try? notification.params(as: PresenceNotice.self), links[host] != nil else { return }
      links[host]?.online = presence.online
      links[host]?.hostGeneration = presence.hostGeneration
      sink.yield(.hosts(hostList()))
    case "axo.client.host.label":
      guard let host, let label = try? notification.params(as: LabelNotice.self).label else { return }
      accountHosts = accountHosts.map { listed in
        listed.hostId == host ? listed.named(label) : listed
      }
      sink.yield(.hosts(hostList()))
    case "axo.client.sessions":
      guard let notice = try? notification.params(as: SessionsNotice.self) else { return }
      if let host { for session in notice.sessions { links[host]?.sessions[session.sessionId] = session } }
      sink.yield(.sessions(hostID: notice.hostId, notice.sessions))
    case "axo.elicitation.requested":
      guard let notice = try? notification.params(as: ElicitationRequestedNotice.self) else { return }
      // While the hosts' indexes come in, what they ask waits for the listing, as in protocol 2.
      let event = AccountEvent.elicitationRequested(hostID: notice.hostId, notice.elicitation)
      if listed { sink.yield(event) } else { held.append(event) }
    case "axo.elicitation.resolved":
      guard let notice = try? notification.params(as: ElicitationResolvedNotice.self) else { return }
      held.removeAll { if case .elicitationRequested(_, let asked) = $0 { asked.id == notice.id } else { false } }
      sink.yield(.elicitationResolved(hostID: notice.hostId, id: notice.id, action: notice.action))
    default:
      // A notice that does not decode is dropped, never guessed at.
      if let event = Self.sessionEvent(from: notification) { sink.yield(event) }
    }
  }

  private static func sessionEvent(from notification: JSONRPCNotification) -> AccountEvent? {
    switch notification.method {
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

  // MARK: - Host sockets

  /// A socket on `host`'s HostDO, which says hello when it connects. It doesn't connect yet.
  private func link(_ host: UUID, connection number: UInt64) -> JSONRPCConnection {
    let clientID = clientID
    let rpc = JSONRPCConnection(transport: hosts!(host)) { [weak self] connection in
      let hello: HostHello = try await connection.call(
        "axo.client.hello",
        params: HostHelloParams(protocolVersion: 3, clientId: clientID.rawValue, connection: number),
        timeout: .seconds(10))
      await self?.said(hello, host: host)
    }
    var link = Link(rpc: rpc)
    link.tasks = [
      Task { [weak self] in
        for await notification in rpc.notifications { await self?.receive(notification, from: host) }
      },
      Task { [weak self] in
        for await _ in rpc.connectionLost { await self?.lost(host, rpc) }
      },
    ]
    links[host] = link
    return rpc
  }

  private func said(_ hello: HostHello, host: UUID) {
    links[host]?.online = hello.online
    links[host]?.hostGeneration = hello.hostGeneration
    for session in hello.sessions { links[host]?.sessions[session.sessionId] = session }
  }

  /// A host's socket ended: so does the connection, which the app connects again.
  private func lost(_ host: UUID, _ rpc: JSONRPCConnection) {
    guard links[host]?.rpc === rpc else { return }
    endConnection.yield()
  }

  /// The account's hosts changed: a socket on each new one, none on one let go. A new host whose
  /// socket fails ends the connection, as any lost socket does.
  private func follow() async throws {
    let listed = Set(accountHosts.map(\.hostId))
    for (host, link) in links where !listed.contains(host) {
      links[host] = nil
      for task in link.tasks { task.cancel() }
      await link.rpc.disconnect()
    }
    let number = nextConnection()
    do {
      for host in listed where links[host] == nil {
        try await link(host, connection: number).connect()
      }
    } catch {
      endConnection.yield()
      throw error
    }
  }

  private func listing() -> ClientHello {
    switch spoken {
    case .relayed: relayedListing
    case .direct: ClientHello(hosts: hostList(), sessions: links.values.flatMap { $0.sessions.values })
    }
  }

  /// The account's hosts, with what each one's HostDO says of its presence.
  private func hostList() -> [ClientHost] {
    accountHosts.map { host in
      guard let link = links[host.hostId] else { return host }
      return host.present(online: link.online, generation: link.hostGeneration)
    }
  }

  /// Numbers connections above the last, from the clock: a HostDO keeps a client's newest
  /// connection and refuses an older one.
  private func nextConnection() -> UInt64 {
    let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    lastConnection = max(now, lastConnection + 1)
    return lastConnection
  }
}

// MARK: - Wire shapes

private struct Empty: Codable, Sendable {}
private struct Hello: Encodable, Sendable {
  let protocolVersion: UInt32
  let clientId: String
}
private struct HostHelloParams: Encodable, Sendable {
  let protocolVersion: UInt32
  let clientId: String
  let connection: UInt64
}
/// A host's index and presence, as its HostDO says hello (protocol 3).
private struct HostHello: Decodable, Sendable {
  let online: Bool
  let hostGeneration: UUID?
  let sessions: [ClientSession]
}
private struct PresenceNotice: Decodable {
  let online: Bool
  let hostGeneration: UUID?
}
private struct LabelNotice: Decodable { let label: String }
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
private struct RenameHostParams: Encodable, Sendable {
  let hostId: String
  let name: String
}
private struct HostRenamed: Decodable, Sendable { let label: String }
private struct CommandParams<Params: Encodable & Sendable>: Encodable, Sendable {
  let hostId: String
  let method: String
  let params: Params
}
private struct ResolveParams: Encodable, Sendable {
  let hostId: String
  let elicitationId: String
  let action: ElicitationAnswer
  let sealed: SealedInput?
  let device: DeviceProof

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hostId, forKey: .hostId)
    try container.encode(elicitationId, forKey: .elicitationId)
    try container.encode(action, forKey: .action)
    try container.encodeIfPresent(sealed, forKey: .sealed)
    try container.encode(device, forKey: .device)
  }

  private enum CodingKeys: String, CodingKey { case hostId, elicitationId, action, sealed, device }
}
private struct Resolved: Decodable, Sendable { let resolved: Bool }
private struct ElicitationRequestedNotice: Decodable {
  let hostId: UUID
  let elicitation: Elicitation
}
private struct ElicitationResolvedNotice: Decodable {
  let hostId: UUID
  let id: String
  let action: ElicitationAction
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
