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

  func testStartingLandsOnANewChatOnTheFirstOnlineMacAndOpensNoExistingChat() async throws {
    let empty = try hostWithSessions("Empty", .offline, ids: [])
    let studio = try hostWithSessions("Studio", .online, ids: [3, 2])
    let (workbench, made) = make([empty, studio])
    await workbench.start()
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: studio.hostId, session: nil))
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertNil(workbench.current?.selectedSession, "the app opens on a blank chat, not on an old one")
    XCTAssertEqual(workbench.current?.hostLabel, "Studio")
    XCTAssertEqual(made.models.count, 1)
  }

  private let creations = Creations()

  private func makeCreating(_ hosts: [RemoteHost], workspaces: [(UUID, String)], refuseCreation: Bool = false) -> PhoneWorkbench {
    let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    let creations = creations
    return PhoneWorkbench(hosts: HostsModel(listing: Listing(hosts: hosts), account: account)) { remote in
      let transport = RespondingTransport()
      transport.workspaces = workspaces.map { (id: $0.0, name: $0.1) }
      transport.creations = creations
      if !refuseCreation { transport.createsSessionNumber = 99 }
      return HostWorkbenchModel(
        host: remote, connection: HostConnection(transport: transport, host: remote.reference),
        history: NoHistory(), account: account)
    }
  }

  private func workspaces(_ names: [String]) -> [(UUID, String)] { names.map { (UUID(), $0) } }

  func testAChatStartsAtOnceWhenTheMacHasOneWorkspaceAndIsAskedForInThatWorkspace() async throws {
    let offline = try hostWithSessions("Old", .offline, ids: [1])
    let online = try hostWithSessions("New", .online, ids: [])
    let project = workspaces(["Project"])
    let workbench = makeCreating([offline, online], workspaces: project)
    await workbench.hosts.refresh()
    XCTAssertEqual(workbench.newChatHost?.label, "New")
    let started = await workbench.startChat(sending: "hello")
    XCTAssertEqual(started, .started)
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: online.hostId, session: 99))
    XCTAssertEqual(workbench.current?.selectedSession?.displayName, "New chat")
    XCTAssertEqual(creations.workspaces, [project[0].0], "a chat is made in a Workspace, never as a bare Session")
    XCTAssertEqual(creations.prompts, ["hello"], "the first message goes to the chat it created")
    XCTAssertFalse(workbench.isDrafting)
  }

  func testSeveralWorkspacesAskWhichAndThenStartThere() async throws {
    let online = try hostWithSessions("New", .online, ids: [1])
    let spaces = workspaces(["One", "Two"])
    let workbench = makeCreating([online], workspaces: spaces)
    await workbench.start()
    guard case .chooseWorkspace(let choices) = await workbench.startChat(sending: "hello") else { return XCTFail("should ask") }
    XCTAssertEqual(choices.map(\.name), ["One", "Two"])
    XCTAssertTrue(creations.workspaces.isEmpty, "nothing is made until the person picks")
    let started = await workbench.startChat(in: choices[1].workspaceId, sending: "hello")
    XCTAssertEqual(started, .started)
    XCTAssertEqual(creations.workspaces, [spaces[1].0])
    XCTAssertEqual(creations.prompts, ["hello"])
  }

  func testAChatIsOnlyCreatedByItsFirstMessageAndTheChatButtonJustGoesBackToABlankOne() async throws {
    let online = try hostWithSessions("New", .online, ids: [1, 2])
    let workbench = makeCreating([online], workspaces: workspaces(["Project"]))
    await workbench.start()
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertTrue(creations.workspaces.isEmpty, "opening the app creates nothing")
    workbench.select(session: 2)
    XCTAssertFalse(workbench.isDrafting)
    XCTAssertEqual(workbench.current?.selectedSession?.sessionId, 2)
    workbench.beginNewChat()
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertNil(workbench.current?.selectedSession)
    XCTAssertTrue(creations.workspaces.isEmpty && creations.prompts.isEmpty, "a blank chat is not a chat")
  }

  func testAMacWithoutWorkspacesSaysSoInsteadOfDoingNothing() async throws {
    let workbench = makeCreating([try hostWithSessions("New", .online, ids: [1])], workspaces: [])
    await workbench.start()
    let started = await workbench.startChat(sending: "hello")
    XCTAssertEqual(started, .failed)
    XCTAssertEqual(workbench.current?.failure, "This Mac has no workspaces yet. Create one in Axo on the Mac.")
  }

  func testAChatTheMacRefusesIsNotStartedAndTheOpenChatStaysOpen() async throws {
    let workbench = makeCreating([try hostWithSessions("New", .online, ids: [1])], workspaces: workspaces(["Project"]), refuseCreation: true)
    await workbench.start()
    workbench.select(session: 1)
    let started = await workbench.startChat(sending: "hello")
    XCTAssertEqual(started, .failed)
    XCTAssertNotNil(workbench.current?.failure)
    XCTAssertEqual(workbench.selection?.session, 1)
  }

  func testNoChatCanStartWhenEveryMacIsOffline() async throws {
    let workbench = makeCreating([try hostWithSessions("Old", .offline, ids: [1])], workspaces: workspaces(["Project"]))
    await workbench.hosts.refresh()
    XCTAssertNil(workbench.newChatHost)
    let started = await workbench.startChat(sending: "hello")
    XCTAssertEqual(started, .failed)
  }

  func testAMacWithoutChatsStillLandsOnABlankOneAndNoMacMeansNothingToOpen() async throws {
    let (workbench, made) = make([try hostWithSessions("Empty", .online, ids: [])])
    await workbench.start()
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertEqual(made.models.count, 1)
    let (none, madeNone) = make([])
    await none.start()
    XCTAssertNil(none.selection)
    XCTAssertTrue(madeNone.models.isEmpty)
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
/// What the transport was asked to create, shared with the test.
final class Creations: @unchecked Sendable {
  private let lock = NSLock()
  private var made: [UUID] = []
  private var said: [String] = []
  var workspaces: [UUID] { lock.withLock { made } }
  /// What was sent to chats, in order.
  var prompts: [String] { lock.withLock { said } }
  func record(_ workspace: UUID) { lock.withLock { made.append(workspace) } }
  func record(prompt: String) { lock.withLock { said.append(prompt) } }
}

final class RespondingTransport: AxoTransport, @unchecked Sendable {
  var workspaces: [(id: UUID, name: String)] = []
  var creations = Creations()
  /// The number of the Session `axo.remote.workspace.session.create` answers with; nil refuses.
  var createsSessionNumber: Int?

  func connect() async throws -> any AxoMessageChannel {
    let channel = ScriptedChannel()
    Task {
      while let request = try? await channel.nextRequest() {
        switch request.method {
        case "axo.protocol.negotiate": channel.reply(to: request.id, result: #"{"protocolVersion":1,"methods":[]}"#)
        case "axo.host.subscribe": channel.reply(to: request.id, result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
        case "axo.remote.workspace.list":
          let list = self.workspaces.map { #"{"workspaceId":"\#($0.id.uuidString.lowercased())","name":"\#($0.name)"}"# }
          channel.reply(to: request.id, result: #"{"workspaces":[\#(list.joined(separator: ","))]}"#)
        case "axo.remote.workspace.session.create":
          let target = request.params["target"] as? [String: Any]
          guard let number = self.createsSessionNumber, let host = (target?["hostId"] as? String).flatMap(UUID.init) else {
            channel.reply(to: request.id, error: -32003, message: "Operation failed"); continue
          }
          if let workspace = (request.params["workspaceId"] as? String).flatMap(UUID.init) { self.creations.record(workspace) }
          channel.reply(to: request.id, result: #"{"session":\#(sessionJSON(host: host, id: number, name: "New chat", shells: [number * 10]))}"#)
        case "axo.remote.session.prompt":
          self.creations.record(prompt: request.params["text"] as? String ?? "")
          channel.reply(to: request.id, result: #"{"accepted":true}"#)
        default: channel.reply(to: request.id, error: -32601, message: "no such method")
        }
      }
    }
    return channel
  }
}
