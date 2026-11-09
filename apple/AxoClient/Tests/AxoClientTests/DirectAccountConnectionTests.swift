import AxoProtocol
import Foundation
import XCTest

@testable import AxoClient

/// Protocol 3 (RFD0032): the account's socket lists the hosts, and each host's HostDO serves its
/// Sessions, records, commands and questions on a socket of its own.
final class DirectAccountConnectionTests: XCTestCase {
  private static let wait: Duration = .seconds(15)
  private let host = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())
  private let newGeneration = UUID()
  private let clientID = ClientID(rawValue: "ios-test-client")!
  private let session = "00000003-0000-4000-8000-000000000003"

  /// What the account's socket answers hello 3: the hosts, offline as far as it knows, and no Sessions.
  private var accountHello: String {
    #"{"hosts":[{"hostId":"\#(lower(host.hostId))","hostGeneration":"\#(lower(host.hostGeneration))","label":"Studio","hostKind":"macos","online":false,"lastSeenAt":"2026-10-16T00:00:00Z"}],"sessions":[]}"#
  }

  /// What the host's HostDO answers hello: its presence and its index.
  private var hostHello: String {
    #"{"online":true,"hostGeneration":"\#(lower(newGeneration))","sessions":[{"hostId":"\#(lower(host.hostId))","sessionId":"\#(session)","metadata":{"name":"Chat","emoji":null,"workspaceId":null,"workspaceName":null,"hasAgent":true,"createdAt":null,"lastMessageAt":null,"archived":false},"epoch":1,"head":2,"status":"ready"}]}"#
  }

  private func lower(_ id: UUID) -> String { id.uuidString.lowercased() }

  private struct Fixture {
    let account: AccountConnection
    let accountTransport: FakeTransport
    let hostTransport: FakeTransport
    let asked: LockedHosts
  }

  /// Which hosts the connection opened a socket on, in order.
  final class LockedHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [UUID] = []
    func add(_ host: UUID) { lock.withLock { hosts.append(host) } }
    var all: [UUID] { lock.withLock { hosts } }
  }

  private func fixture(
    account: FakeTransport? = nil, host: FakeTransport? = nil
  ) -> Fixture {
    let accountTransport = account ?? FakeTransport(hello: accountHello)
    let hostTransport = host ?? FakeTransport(hello: hostHello)
    let asked = LockedHosts()
    let connection = AccountConnection(
      transport: accountTransport, clientID: clientID,
      hosts: { id in
        asked.add(id)
        return hostTransport
      })
    return Fixture(account: connection, accountTransport: accountTransport, hostTransport: hostTransport, asked: asked)
  }

  private func next(_ account: AccountConnection) async throws -> AccountEvent? {
    var iterator = account.events.makeAsyncIterator()
    return try await withThrowingTaskGroup(of: AccountEvent?.self) { group in
      group.addTask { await iterator.next() }
      group.addTask {
        try await Task.sleep(for: Self.wait)
        return nil
      }
      defer { group.cancelAll() }
      return try await group.next() ?? nil
    }
  }

  private func request(_ channel: FakeChannel, _ index: Int) async throws -> [String: Any] {
    let raw = try await channel.rawRequests(count: index + 1)[index]
    return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
  }

  func testHelloListsTheHostsFromTheAccountAndEachHostsPresenceAndSessionsFromItsHostDO() async throws {
    let f = fixture()
    try await f.account.connect()
    let accountChannel = try await f.accountTransport.channel(0)
    let hostChannel = try await f.hostTransport.channel(0)
    XCTAssertEqual(accountChannel.helloParams?["protocolVersion"] as? Int, 3)
    XCTAssertEqual(hostChannel.helloParams?["protocolVersion"] as? Int, 3)
    XCTAssertEqual(hostChannel.helloParams?["clientId"] as? String, "ios-test-client")
    let number = try XCTUnwrap(hostChannel.helloParams?["connection"] as? Int)
    XCTAssertGreaterThan(number, 0, "a HostDO keeps the newest connection: it is numbered")
    XCTAssertEqual(f.asked.all, [host.hostId])

    guard case .hello(let listing)? = try await next(f.account) else { return XCTFail("expected hello") }
    XCTAssertEqual(listing.hosts.map(\.online), [true], "presence is the HostDO's")
    XCTAssertEqual(listing.hosts.map(\.hostGeneration), [newGeneration])
    XCTAssertEqual(listing.hosts.map(\.label), ["Studio"])
    XCTAssertEqual(listing.sessions.map(\.sessionId), [3])

    // A new connection is numbered above the last.
    hostChannel.endFromPeer()
    try await Task.sleep(for: .milliseconds(50))
    try await f.account.connect()
    let again = try await f.hostTransport.channel(1)
    XCTAssertGreaterThan(try XCTUnwrap(again.helloParams?["connection"] as? Int), number)
  }

  func testOpensRecordsAcknowledgementsAndCommandsGoToTheHostsSocket() async throws {
    let f = fixture()
    try await f.account.connect()
    let accountChannel = try await f.accountTransport.channel(0)
    let hostChannel = try await f.hostTransport.channel(0)
    guard case .hello? = try await next(f.account) else { return XCTFail() }

    async let opened = f.account.open(3, on: host.hostId, have: (epoch: 1, cursor: 2))
    let open = try await request(hostChannel, 0)
    XCTAssertEqual(open["method"] as? String, "axo.client.session.open")
    hostChannel.reply(to: try XCTUnwrap(open["id"] as? Int), result: #"{"epoch":1,"records":[],"cursor":2,"older":null,"progress":[]}"#)
    _ = try await opened

    hostChannel.send(raw: #"{"jsonrpc":"2.0","method":"axo.client.session.records","params":{"sessionId":"\#(session)","epoch":1,"records":[{"cursor":3,"id":"e3","format":"pi/3","line":"{}","hash":"sha256:\#(String(repeating: "0", count: 64))"}],"cursor":3}}"#)
    guard case .records(_, 1, let records, 3)? = try await next(f.account) else { return XCTFail("the host's records") }
    XCTAssertEqual(records.map(\.id), ["e3"])
    await f.account.acknowledge(3, cursor: 3)
    let ack = try await request(hostChannel, 1)
    XCTAssertEqual(ack["method"] as? String, "axo.client.session.ack")

    async let prompted: Void = HostConnection(account: f.account, host: host).promptPi(in: 3, text: "hi", commandId: UUID())
    let command = try await request(hostChannel, 2)
    XCTAssertEqual(command["method"] as? String, "axo.client.command")
    hostChannel.reply(to: try XCTUnwrap(command["id"] as? Int), result: #"{"accepted":true}"#)
    try await prompted

    await f.account.close(3)
    let close = try await request(hostChannel, 3)
    XCTAssertEqual(close["method"] as? String, "axo.client.session.close")
    XCTAssertEqual(accountChannel.sentCount, 0, "the account's socket carries none of it")
  }

  func testPresenceAndNamesFromAHostDOUpdateTheHostList() async throws {
    let f = fixture()
    try await f.account.connect()
    let hostChannel = try await f.hostTransport.channel(0)
    guard case .hello? = try await next(f.account) else { return XCTFail() }
    hostChannel.send(raw: #"{"jsonrpc":"2.0","method":"axo.client.host.presence","params":{"online":false,"hostGeneration":null}}"#)
    guard case .hosts(let offline)? = try await next(f.account) else { return XCTFail("presence") }
    XCTAssertEqual(offline.map(\.online), [false])
    XCTAssertEqual(offline.map(\.hostGeneration), [host.hostGeneration], "with no generation, the account's stands")
    hostChannel.send(raw: #"{"jsonrpc":"2.0","method":"axo.client.host.label","params":{"label":"Leo's Studio"}}"#)
    guard case .hosts(let renamed)? = try await next(f.account) else { return XCTFail("label") }
    XCTAssertEqual(renamed.map(\.label), ["Leo's Studio"])
  }

  func testWhatAHostAsksWhileTheIndexesComeInFollowsTheListing() async throws {
    let f = fixture()
    // The host asks before it answers hello: the question waits for the listing.
    let hostTransport = f.hostTransport
    let elicitation = #"{"id":"q1","sessionId":"\#(session)","kind":"confirm","askedBy":"computerUse","message":"Delete it?","createdAt":1,"expiresAt":2}"#
    Task {
      let channel = try await hostTransport.channel(0)
      channel.send(raw: #"{"jsonrpc":"2.0","method":"axo.elicitation.requested","params":{"hostId":"\#(self.lower(self.host.hostId))","elicitation":\#(elicitation)}}"#)
    }
    try await f.account.connect()
    var events: [AccountEvent] = []
    while events.count < 2, let event = try await next(f.account) { events.append(event) }
    guard case .hello? = events.first else { return XCTFail("the listing first: \(events)") }
    guard case .elicitationRequested(let from, let asked)? = events.last else { return XCTFail("\(events)") }
    XCTAssertEqual(from, host.hostId)
    XCTAssertEqual(asked.id, "q1")
  }

  func testACommandForAHostWithNoSocketIsRefusedAsOfflineAndSentNowhere() async throws {
    let f = fixture()
    try await f.account.connect()
    guard case .hello? = try await next(f.account) else { return XCTFail() }
    let stranger = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())
    do {
      try await HostConnection(account: f.account, host: stranger).promptPi(in: 3, text: "hi", commandId: UUID())
      XCTFail("nothing can carry it")
    } catch {
      guard case .serverRejected(-32005, _) = error as? AxoClientError else { return XCTFail("\(error)") }
    }
    let accountChannel = try await f.accountTransport.channel(0)
    XCTAssertEqual(accountChannel.sentCount, 0)
  }

  func testAnAccountThatRefusesHello3IsSpokenToInProtocol2() async throws {
    let relayed = #"{"hosts":[],"sessions":[]}"#
    let f = fixture(account: FakeTransport(hello: relayed, refusingHello: [3: -32602]))
    try await f.account.connect()
    let second = try await f.accountTransport.channel(1)
    XCTAssertEqual(second.helloParams?["protocolVersion"] as? Int, 2)
    let first = try await f.accountTransport.channel(0)
    XCTAssertTrue(first.isClosed)
    guard case .hello? = try await next(f.account) else { return XCTFail() }
    XCTAssertEqual(f.asked.all, [], "no host sockets in protocol 2")

    // It stays on 2: commands go through the account.
    async let prompted: Void = HostConnection(account: f.account, host: host).promptPi(in: 3, text: "hi", commandId: UUID())
    let command = try await request(second, 0)
    XCTAssertEqual(command["method"] as? String, "axo.client.command")
    second.reply(to: try XCTUnwrap(command["id"] as? Int), result: #"{"accepted":true}"#)
    try await prompted
  }

  func testAnAccountHelloThatFailsOtherwiseFailsThisConnectionAndKeepsProtocol3() async throws {
    let f = fixture(account: FakeTransport(hello: accountHello, refusingHello: [3: -32603]))
    do {
      try await f.account.connect()
      XCTFail("a failed hello fails the connection")
    } catch {
      guard case .serverRejected(-32603, _) = error as? AxoClientError else { return XCTFail("\(error)") }
    }
    let failed = try await f.accountTransport.channel(0)
    XCTAssertTrue(failed.isClosed)
    XCTAssertEqual(f.accountTransport.connectCount, 1, "not a refusal of protocol 3: no fallback")
    try? await f.account.connect()
    let again = try await f.accountTransport.channel(1)
    XCTAssertEqual(again.helloVersion, 3, "the next connection tries 3 again")
  }

  func testAHostSocketThatFailsBeforeItsIndexSendsTheConnectionBackTo2() async throws {
    let f = fixture(host: FakeTransport(failingConnects: 1, hello: hostHello))
    try await f.account.connect()
    let direct = try await f.accountTransport.channel(0)
    let relayed = try await f.accountTransport.channel(1)
    XCTAssertEqual(direct.helloParams?["protocolVersion"] as? Int, 3)
    XCTAssertEqual(relayed.helloParams?["protocolVersion"] as? Int, 2)
    XCTAssertEqual(f.hostTransport.connectCount, 1, "not tried again on this connection")
  }

  func testAHostSocketEndingEndsTheConnection() async throws {
    let f = fixture()
    try await f.account.connect()
    let accountChannel = try await f.accountTransport.channel(0)
    let hostChannel = try await f.hostTransport.channel(0)
    var lost = f.account.connectionLost.makeAsyncIterator()
    hostChannel.endFromPeer()
    let ended: Void? = await lost.next()
    XCTAssertNotNil(ended)
    XCTAssertTrue(accountChannel.isClosed)
  }
}
