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

  private func makeCreating(
    _ hosts: [RemoteHost], workspaces: [(UUID, String)], refuseCreation: Bool = false, refusePrompts: Bool = false
  ) -> PhoneWorkbench {
    let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    let creations = creations
    return PhoneWorkbench(hosts: HostsModel(listing: Listing(hosts: hosts), account: account)) { remote in
      let transport = RespondingTransport()
      transport.workspaces = workspaces.map { (id: $0.0, name: $0.1) }
      transport.creations = creations
      if !refuseCreation { transport.createsSessionNumber = 99 }
      transport.refusesPrompts = refusePrompts
      return HostWorkbenchModel(
        host: remote, connection: HostConnection(transport: transport, host: remote.reference),
        history: NoHistory(), account: account)
    }
  }

  private func workspaces(_ names: [String]) -> [(UUID, String)] { names.map { (UUID(), $0) } }

  /// Types `text` into the open chat's box.
  private func type(_ text: String, in workbench: PhoneWorkbench) throws {
    workbench.setDraft(text, for: try XCTUnwrap(workbench.selection))
  }

  func testAChatStartsInTheMacsHomeWorkspaceWithItsFirstMessage() async throws {
    let offline = try hostWithSessions("Old", .offline, ids: [1])
    let online = try hostWithSessions("New", .online, ids: [])
    let workbench = makeCreating([offline, online], workspaces: workspaces(["Project", "Website"]))
    await workbench.start()
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: online.hostId, session: nil), "a blank chat on the Mac that is online")
    try type("hello", in: workbench)
    let sent = await workbench.send()
    XCTAssertEqual(sent, .sent)
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: online.hostId, session: 99))
    XCTAssertEqual(workbench.current?.selectedSession?.displayName, "New chat")
    XCTAssertEqual(creations.places, [.home], "however many Workspaces there are, a new chat goes Home")
    XCTAssertEqual(creations.prompts, ["hello"], "the first message goes to the chat it created")
    XCTAssertFalse(workbench.isDrafting)
    XCTAssertEqual(workbench.draft(for: PhoneWorkbench.Selection(host: online.hostId, session: nil)), "", "the blank chat's box is empty again")
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "")
    XCTAssertEqual(workbench.current?.pendingPrompts[99]?.map(\.text), ["hello"], "shown until the agent records it")
    XCTAssertEqual(workbench.current?.pendingPrompts[99]?.first?.state, .sent)
  }

  func testAChatCanStartInAChosenWorkspaceInstead() async throws {
    let online = try hostWithSessions("New", .online, ids: [1])
    let spaces = workspaces(["One", "Two"])
    let workbench = makeCreating([online], workspaces: spaces)
    await workbench.start()
    try type("hello", in: workbench)
    let sent = await workbench.send(in: .workspace(spaces[1].0))
    XCTAssertEqual(sent, .sent)
    XCTAssertEqual(creations.places, [.workspace(spaces[1].0)])
    XCTAssertEqual(creations.prompts, ["hello"])
    XCTAssertEqual(workbench.selection?.session, 99)
    try type("more", in: workbench)
    let again = await workbench.send(in: .workspace(spaces[0].0))
    XCTAssertEqual(again, .failed, "only a new chat can be placed; an open one already has its Workspace")
    XCTAssertEqual(creations.places.count, 1)
  }

  func testAChatIsOnlyCreatedByItsFirstMessageAndTheChatButtonJustGoesBackToABlankOne() async throws {
    let online = try hostWithSessions("New", .online, ids: [1, 2])
    let workbench = makeCreating([online], workspaces: workspaces(["Project"]))
    await workbench.start()
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertTrue(creations.places.isEmpty, "opening the app creates nothing")
    workbench.select(session: 2)
    XCTAssertFalse(workbench.isDrafting)
    XCTAssertEqual(workbench.current?.selectedSession?.sessionId, 2)
    workbench.beginNewChat()
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertNil(workbench.current?.selectedSession)
    let outcome = await workbench.send()
    XCTAssertEqual(outcome, .failed, "an empty box sends nothing")
    XCTAssertTrue(creations.places.isEmpty && creations.prompts.isEmpty, "a blank chat is not a chat")
  }

  func testEachChatKeepsItsOwnDraftWhileOthersAreOpen() async throws {
    let online = try hostWithSessions("New", .online, ids: [1, 2])
    let workbench = makeCreating([online], workspaces: workspaces(["Project"]))
    await workbench.start()
    try type("an idea", in: workbench)
    workbench.select(session: 1)
    try type("for one", in: workbench)
    workbench.select(session: 2)
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "")
    workbench.select(session: 1)
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "for one")
    workbench.beginNewChat()
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "an idea")
  }

  func testAMessageLeavesTheBoxAsItGoesAndComesBackIfTheMacRefusesIt() async throws {
    let online = try hostWithSessions("New", .online, ids: [1])
    let workbench = makeCreating([online], workspaces: workspaces(["Project"]), refusePrompts: true)
    await workbench.start()
    workbench.select(session: 1)
    try type("  run it  ", in: workbench)
    let outcome = await workbench.send()
    XCTAssertEqual(outcome, .failed)
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "run it", "a refusal loses nothing")
    XCTAssertNil(workbench.current?.pendingPrompts[1], "a refused message is not shown as sent")
    XCTAssertNotNil(workbench.current?.failure)
    XCTAssertFalse(workbench.isSending)
  }

  func testAFirstMessageTheMacRefusesStaysInTheBoxOfTheChatItStarted() async throws {
    let online = try hostWithSessions("New", .online, ids: [])
    let workbench = makeCreating([online], workspaces: workspaces(["Project"]), refusePrompts: true)
    await workbench.start()
    try type("hello", in: workbench)
    let outcome = await workbench.send()
    XCTAssertEqual(outcome, .failed)
    XCTAssertEqual(workbench.selection?.session, 99, "the chat exists and is open")
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "hello")
  }

  func testAChatTheMacRefusesToCreateLeavesTheBlankChatAndItsWords() async throws {
    let workbench = makeCreating([try hostWithSessions("New", .online, ids: [1])], workspaces: workspaces(["Project"]), refuseCreation: true)
    await workbench.start()
    try type("hello", in: workbench)
    let sent = await workbench.send()
    XCTAssertEqual(sent, .failed)
    XCTAssertNotNil(workbench.current?.failure)
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "hello")
  }

  func testNoChatCanStartWhenEveryMacIsOffline() async throws {
    let workbench = makeCreating([try hostWithSessions("Old", .offline, ids: [1])], workspaces: workspaces(["Project"]))
    await workbench.start()
    XCTAssertNil(workbench.newChatHost)
    try type("hello", in: workbench)
    let sent = await workbench.send()
    XCTAssertEqual(sent, .failed)
    XCTAssertEqual(workbench.current?.failure, "Old is offline.")
    XCTAssertTrue(creations.places.isEmpty)
  }

  func testTheMenuListsTheOpenMacsChatsAsTheyAreNowNotAsTheyWereListed() async throws {
    let online = try hostWithSessions("New", .online, ids: [1])
    let other = try hostWithSessions("Other", .online, ids: [5])
    let workbench = makeCreating([online, other], workspaces: workspaces(["Project"]))
    await workbench.start()
    try type("hello", in: workbench)
    _ = await workbench.send()
    XCTAssertEqual(workbench.sessions(of: online).map(\.sessionId), [1, 99], "the chat just made is listed")
    XCTAssertEqual(workbench.hosts.hosts.first?.sessions.map(\.sessionId), [1], "the listing itself is older")
    XCTAssertEqual(workbench.sessions(of: other).map(\.sessionId), [5], "other Macs are as listed")
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
  private var made: [NewChatPlace] = []
  private var said: [String] = []
  /// Where chats were made, in order.
  var places: [NewChatPlace] { lock.withLock { made } }
  /// What was sent to chats, in order.
  var prompts: [String] { lock.withLock { said } }
  func record(_ place: NewChatPlace) { lock.withLock { made.append(place) } }
  func record(prompt: String) { lock.withLock { said.append(prompt) } }
}

final class RespondingTransport: AxoTransport, @unchecked Sendable {
  var workspaces: [(id: UUID, name: String)] = []
  var creations = Creations()
  /// The number of the Session a create answers with; nil refuses.
  var createsSessionNumber: Int?
  var refusesPrompts = false

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
        case "axo.remote.session.create", "axo.remote.workspace.session.create":
          let target = request.params["target"] as? [String: Any]
          guard let number = self.createsSessionNumber, let host = (target?["hostId"] as? String).flatMap(UUID.init) else {
            channel.reply(to: request.id, error: -32003, message: "Operation failed"); continue
          }
          if request.method == "axo.remote.session.create" {
            self.creations.record(.home)
          } else if let workspace = (request.params["workspaceId"] as? String).flatMap(UUID.init) {
            self.creations.record(.workspace(workspace))
          }
          channel.reply(to: request.id, result: #"{"session":\#(sessionJSON(host: host, id: number, name: "New chat", shells: [number * 10]))}"#)
        case "axo.remote.session.prompt":
          guard !self.refusesPrompts else {
            channel.reply(to: request.id, error: -32003, message: "Operation failed"); continue
          }
          self.creations.record(prompt: request.params["text"] as? String ?? "")
          channel.reply(to: request.id, result: #"{"accepted":true}"#)
        default: channel.reply(to: request.id, error: -32601, message: "no such method")
        }
      }
    }
    return channel
  }
}
