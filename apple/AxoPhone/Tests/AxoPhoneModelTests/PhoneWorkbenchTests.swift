import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

@MainActor
final class PhoneWorkbenchTests: XCTestCase {
  private struct Listing: HostListing {
    let hosts: [RemoteHost]
    func hosts() async throws -> [RemoteHost] { hosts }
  }

  private func make(_ hosts: [RemoteHost]) -> (PhoneWorkbench, Made) {
    let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    let made = Made()
    let workbench = PhoneWorkbench(hosts: HostsModel(listing: Listing(hosts: hosts), account: account)) { remote in
      let model = HostWorkbenchModel(
        host: remote, connection: HostConnection(transport: RespondingTransport(), host: remote.reference),
        history: NoHistory(), account: account)
      made.models.append(model)
      return model
    }
    return (workbench, made)
  }

  private func hostWithSessions(_ label: String, _ status: RemoteHostStatus, ids: [Int]) throws -> RemoteHost {
    let id = UUID()
    let sessions = ids.map { sessionJSON(host: id, id: $0, name: "S\($0)", shells: [$0 * 10]) }
    return try JSONDecoder().decode(
      RemoteHost.self,
      from: Data("""
        {"hostId":"\(id.uuidString)","hostGeneration":"\(UUID().uuidString)","label":"\(label)","hostKind":"macos",
        "status":"\(status.rawValue)","stale":\(status == .offline),"lastSeenAt":"2026-10-16T00:00:00Z",
        "sessions":[\(sessions.joined(separator: ","))]}
        """.utf8))
  }

  func testStartingOpensTheFirstMacThatHasSessionsAndItsFirstSession() async throws {
    let empty = try hostWithSessions("Empty", .online, ids: [])
    let studio = try hostWithSessions("Studio", .online, ids: [3, 2])
    let (workbench, made) = make([empty, studio])
    await workbench.start()
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: studio.hostId, session: 2))
    XCTAssertEqual(workbench.current?.hostLabel, "Studio")
    XCTAssertEqual(made.models.count, 1)
  }

  private func makeCreating(_ hosts: [RemoteHost], creates: Bool) -> PhoneWorkbench {
    let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    return PhoneWorkbench(hosts: HostsModel(listing: Listing(hosts: hosts), account: account)) { remote in
      let transport = RespondingTransport()
      if creates { transport.createsSession = (remote.hostId, 99) }
      return HostWorkbenchModel(
        host: remote, connection: HostConnection(transport: transport, host: remote.reference),
        history: NoHistory(), account: account)
    }
  }

  func testStartingAChatOpensANewSessionOnTheFirstOnlineMacWhenNoneIsOpen() async throws {
    let offline = try hostWithSessions("Old", .offline, ids: [1])
    let online = try hostWithSessions("New", .online, ids: [])
    let workbench = makeCreating([offline, online], creates: true)
    await workbench.hosts.refresh()
    XCTAssertEqual(workbench.newChatHost?.label, "New")
    let started = await workbench.startChat()
    XCTAssertTrue(started)
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: online.hostId, session: 99))
    XCTAssertEqual(workbench.current?.selectedSession?.displayName, "New chat")
  }

  func testAChatTheMacRefusesIsNotStartedAndSaysWhy() async throws {
    let online = try hostWithSessions("New", .online, ids: [1])
    let workbench = makeCreating([online], creates: false)
    await workbench.start()
    let started = await workbench.startChat()
    XCTAssertFalse(started)
    XCTAssertNotNil(workbench.current?.failure)
    XCTAssertEqual(workbench.selection?.session, 1, "the open chat stays open")
  }

  func testNoChatCanStartWhenEveryMacIsOffline() async throws {
    let workbench = makeCreating([try hostWithSessions("Old", .offline, ids: [1])], creates: true)
    await workbench.hosts.refresh()
    XCTAssertNil(workbench.newChatHost)
    let started = await workbench.startChat()
    XCTAssertFalse(started)
  }

  func testWithoutAnySessionsNothingOpens() async throws {
    let (workbench, made) = make([try hostWithSessions("Empty", .online, ids: [])])
    await workbench.start()
    XCTAssertNil(workbench.selection)
    XCTAssertNil(workbench.current)
    XCTAssertTrue(made.models.isEmpty)
  }

  func testOpeningAnotherMacClosesTheFirstAndSameMacJustSwitchesSession() async throws {
    let a = try hostWithSessions("A", .online, ids: [1, 2])
    let b = try hostWithSessions("B", .offline, ids: [5])
    let (workbench, made) = make([a, b])
    await workbench.start()
    let first = try XCTUnwrap(workbench.current)
    try await eventually { first.isFollowing }

    workbench.select(session: 2)
    XCTAssertEqual(workbench.selection?.session, 2)
    XCTAssertTrue(workbench.current === first, "the same Mac keeps its connection")
    XCTAssertEqual(first.selectedSessionID, 2)
    XCTAssertEqual(made.models.count, 1)

    workbench.select(host: b.hostId, session: 5)
    XCTAssertFalse(workbench.current === first)
    XCTAssertEqual(workbench.current?.hostLabel, "B")
    XCTAssertFalse(first.isFollowing, "the Mac that was left is disconnected")
    try await eventually { workbench.current?.isFollowing == true }
    XCTAssertEqual(made.models.count, 2)
  }

  func testAnUnknownMacIsNotOpenedAndClosingForgetsEverything() async throws {
    let a = try hostWithSessions("A", .online, ids: [1])
    let (workbench, _) = make([a])
    await workbench.start()
    workbench.select(host: UUID(), session: 1)
    XCTAssertEqual(workbench.selection?.host, a.hostId, "nothing changed")
    workbench.close()
    XCTAssertNil(workbench.selection)
    XCTAssertNil(workbench.current)
  }

  func testAMacThatVanishedFromTheAccountClosesOnRefresh() async throws {
    let a = try hostWithSessions("A", .online, ids: [1])
    let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    let listing = SwitchableListing([a])
    let workbench = PhoneWorkbench(hosts: HostsModel(listing: listing, account: account)) { remote in
      HostWorkbenchModel(
        host: remote, connection: HostConnection(transport: ScriptedTransport(), host: remote.reference),
        history: NoHistory(), account: account)
    }
    await workbench.start()
    XCTAssertNotNil(workbench.current)
    listing.set([])
    await workbench.refresh()
    XCTAssertNil(workbench.current)
  }

  private func eventually(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("condition never held") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

final class Made: @unchecked Sendable {
  @MainActor var models: [HostWorkbenchModel] = []
}

final class SwitchableListing: HostListing, @unchecked Sendable {
  private let lock = NSLock()
  private var hosts: [RemoteHost]
  init(_ hosts: [RemoteHost]) { self.hosts = hosts }
  func set(_ hosts: [RemoteHost]) { lock.withLock { self.hosts = hosts } }
  func hosts() async throws -> [RemoteHost] { lock.withLock { hosts } }
}

/// A relay that answers the two calls opening a Mac needs.
final class RespondingTransport: AxoTransport, @unchecked Sendable {
  /// When set, `axo.remote.session.create` answers with a new Session of this number on this host.
  var createsSession: (host: UUID, id: Int)?

  func connect() async throws -> any AxoMessageChannel {
    let channel = ScriptedChannel()
    Task {
      while let request = try? await channel.nextRequest() {
        switch request.method {
        case "axo.protocol.negotiate": channel.reply(to: request.id, result: #"{"protocolVersion":1,"methods":[]}"#)
        case "axo.host.subscribe": channel.reply(to: request.id, result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
        case "axo.remote.session.create":
          if let created = self.createsSession {
            channel.reply(to: request.id, result: #"{"session":\#(sessionJSON(host: created.host, id: created.id, name: "New chat", shells: [created.id * 10]))}"#)
          } else {
            channel.reply(to: request.id, error: -32003, message: "Operation failed")
          }
        default: channel.reply(to: request.id, error: -32601, message: "no such method")
        }
      }
    }
    return channel
  }
}
