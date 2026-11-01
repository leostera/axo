import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// A Mac of the account, as the ClientDO lists it.
struct Mac {
  let id = UUID()
  var generation = UUID()
  let label: String
  var online: Bool
  var sessions: [SessionID]

  init(_ label: String, online: Bool, sessions: [SessionID] = []) {
    self.label = label
    self.online = online
    self.sessions = sessions
  }

  var hostJSON: String { Wire.host(id, label, online: online, generation: generation) }
  var sessionsJSON: [String] {
    sessions.map { Wire.session(host: id, id: $0, name: "S\($0.rawValue.prefix(8))", createdAt: Int64(sessions.firstIndex(of: $0)! + 1)) }
  }

  static func listing(_ macs: [Mac]) -> String {
    Wire.listing(hosts: macs.map(\.hostJSON), sessions: macs.flatMap(\.sessionsJSON))
  }
}

/// What the Macs were asked to do, shared with the test.
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

/// The phone with its account socket, a relay that answers what the Macs would, and every Mac
/// model it made.
@MainActor
final class PhoneWorld {
  let transport: ScriptedTransport
  let feed: AccountConnection
  let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
  let creations = Creations()
  private(set) var workbench: PhoneWorkbench!
  private(set) var made: [HostWorkbenchModel] = []

  init(
    _ macs: [Mac], workspaces: [(UUID, String)] = [], createsSession: SessionID? = 99, refusesPrompts: Bool = false,
    answers: Bool = true
  ) {
    transport = ScriptedTransport(listing: Mac.listing(macs))
    feed = AccountConnection(transport: transport, clientID: ClientID(rawValue: "test-client")!)
    if answers { transport.responder = Self.responder(workspaces: workspaces, createsSession: createsSession, refusesPrompts: refusesPrompts, creations: creations) }
    let feed = feed
    let account = account
    workbench = PhoneWorkbench(
      hosts: HostsModel(profile: NoProfile()), feed: feed, account: account, reconnectDelays: [.milliseconds(10)]
    ) { [unowned self] remote in
      let model = HostWorkbenchModel(
        host: remote, connection: HostConnection(account: feed, host: remote.reference), feed: feed, account: account)
      self.made.append(model)
      return model
    }
  }

  /// Answers the Macs' commands and opens every chat empty.
  private static func responder(
    workspaces: [(UUID, String)], createsSession: SessionID?, refusesPrompts: Bool, creations: Creations
  ) -> @Sendable (ScriptedRequest) -> ScriptedReply? {
    let spaces = workspaces.map { #"{"workspaceId":"\#($0.0.uuidString.lowercased())","name":"\#($0.1)"}"# }
    return { request in
      switch request.method {
      case "axo.client.session.open": return .result(Wire.opened(epoch: nil, []))
      case "axo.remote.workspace.list": return .result(#"{"workspaces":[\#(spaces.joined(separator: ","))]}"#)
      case "axo.remote.session.create", "axo.remote.workspace.session.create":
        let target = request.params["target"] as? [String: Any]
        guard let session = createsSession, let host = (target?["hostId"] as? String).flatMap(UUID.init) else {
          return .error(-32003, "Operation failed")
        }
        if request.method == "axo.remote.session.create" {
          creations.record(.home)
        } else if let workspace = (request.params["workspaceId"] as? String).flatMap(UUID.init) {
          creations.record(.workspace(workspace))
        }
        let number = Int(session.rawValue.prefix(8), radix: 16)!
        return .result(#"{"session":\#(sessionJSON(host: host, id: number, name: "New chat", shells: []))}"#)
      case "axo.remote.session.prompt":
        guard !refusesPrompts else { return .error(-32003, "Operation failed") }
        creations.record(prompt: request.params["text"] as? String ?? "")
        return .result(#"{"accepted":true}"#)
      case "axo.remote.session.key": return .result(#"{"accepted":true}"#)
      default: return nil
      }
    }
  }

  /// Starts and waits for the first listing.
  func start() async throws {
    await workbench.start()
    try await eventually { self.workbench.link == .connected && self.workbench.hosts.phase == .loaded }
  }
}

private struct NoProfile: SignedInAccountLoading {
  func signedInAccount() async -> SignedInAccount? { nil }
}

@MainActor
final class PhoneWorkbenchTests: XCTestCase {
  private func workspaces(_ names: [String]) -> [(UUID, String)] { names.map { (UUID(), $0) } }

  /// Types `text` into the open chat's box.
  private func type(_ text: String, in workbench: PhoneWorkbench) throws {
    workbench.setDraft(text, for: try XCTUnwrap(workbench.selection))
  }

  func testStartingLandsOnANewChatOnTheFirstOnlineMacAndOpensNoExistingChat() async throws {
    let empty = Mac("Empty", online: false)
    let studio = Mac("Studio", online: true, sessions: [3, 2])
    let world = PhoneWorld([empty, studio])
    try await world.start()
    let workbench = world.workbench!
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: studio.id, session: nil))
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertNil(workbench.current?.selectedSession, "the app opens on a blank chat, not on an old one")
    XCTAssertEqual(workbench.current?.hostLabel, "Studio")
    XCTAssertEqual(world.made.count, 1)
    XCTAssertEqual(workbench.hosts.hosts.map(\.label), ["Studio", "Empty"], "online Macs first")
  }

  func testAChatStartsInTheMacsHomeWorkspaceWithItsFirstMessage() async throws {
    let offline = Mac("Old", online: false, sessions: [1])
    let online = Mac("New", online: true)
    let world = PhoneWorld([offline, online], workspaces: workspaces(["Project", "Website"]))
    try await world.start()
    let workbench = world.workbench!
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: online.id, session: nil), "a blank chat on the Mac that is online")
    try type("hello", in: workbench)
    let sent = await workbench.send()
    XCTAssertEqual(sent, .sent)
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: online.id, session: 99))
    XCTAssertEqual(workbench.current?.selectedSession?.displayName, "New chat")
    XCTAssertEqual(world.creations.places, [.home], "however many Workspaces there are, a new chat goes Home")
    XCTAssertEqual(world.creations.prompts, ["hello"], "the first message goes to the chat it created")
    XCTAssertFalse(workbench.isDrafting)
    XCTAssertEqual(workbench.draft(for: PhoneWorkbench.Selection(host: online.id, session: nil)), "", "the blank chat's box is empty again")
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "")
    XCTAssertEqual(workbench.current?.pendingPrompts[99]?.map(\.text), ["hello"], "shown until the agent records it")
    XCTAssertEqual(workbench.current?.pendingPrompts[99]?.first?.state, .sent)
  }

  func testAChatCanStartInAChosenWorkspaceInstead() async throws {
    let online = Mac("New", online: true, sessions: [1])
    let spaces = workspaces(["One", "Two"])
    let world = PhoneWorld([online], workspaces: spaces)
    try await world.start()
    let workbench = world.workbench!
    try type("hello", in: workbench)
    let sent = await workbench.send(in: .workspace(spaces[1].0))
    XCTAssertEqual(sent, .sent)
    XCTAssertEqual(world.creations.places, [.workspace(spaces[1].0)])
    XCTAssertEqual(world.creations.prompts, ["hello"])
    XCTAssertEqual(workbench.selection?.session, 99)
    try type("more", in: workbench)
    let again = await workbench.send(in: .workspace(spaces[0].0))
    XCTAssertEqual(again, .failed, "only a new chat can be placed; an open one already has its Workspace")
    XCTAssertEqual(world.creations.places.count, 1)
  }

  func testAChatIsOnlyCreatedByItsFirstMessageAndTheChatButtonJustGoesBackToABlankOne() async throws {
    let world = PhoneWorld([Mac("New", online: true, sessions: [1, 2])], workspaces: workspaces(["Project"]))
    try await world.start()
    let workbench = world.workbench!
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertTrue(world.creations.places.isEmpty, "opening the app creates nothing")
    workbench.select(session: 2)
    XCTAssertFalse(workbench.isDrafting)
    XCTAssertEqual(workbench.current?.selectedSession?.sessionId, 2)
    workbench.beginNewChat()
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertNil(workbench.current?.selectedSession)
    let outcome = await workbench.send()
    XCTAssertEqual(outcome, .failed, "an empty box sends nothing")
    XCTAssertTrue(world.creations.places.isEmpty && world.creations.prompts.isEmpty, "a blank chat is not a chat")
  }

  func testEachChatKeepsItsOwnDraftWhileOthersAreOpen() async throws {
    let world = PhoneWorld([Mac("New", online: true, sessions: [1, 2])])
    try await world.start()
    let workbench = world.workbench!
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
    let world = PhoneWorld([Mac("New", online: true, sessions: [1])], refusesPrompts: true)
    try await world.start()
    let workbench = world.workbench!
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
    let world = PhoneWorld([Mac("New", online: true)], refusesPrompts: true)
    try await world.start()
    let workbench = world.workbench!
    try type("hello", in: workbench)
    let outcome = await workbench.send()
    XCTAssertEqual(outcome, .failed)
    XCTAssertEqual(workbench.selection?.session, 99, "the chat exists and is open")
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "hello")
  }

  func testAChatTheMacRefusesToCreateLeavesTheBlankChatAndItsWords() async throws {
    let world = PhoneWorld([Mac("New", online: true, sessions: [1])], createsSession: nil)
    try await world.start()
    let workbench = world.workbench!
    try type("hello", in: workbench)
    let sent = await workbench.send()
    XCTAssertEqual(sent, .failed)
    XCTAssertNotNil(workbench.current?.failure)
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "hello")
  }

  func testANewChatsMacIsChosenByTheMessageBoxAndWhatIsTypedComesAlong() async throws {
    let studio = Mac("Studio", online: true, sessions: [1])
    let laptop = Mac("Laptop", online: true)
    let world = PhoneWorld([studio, laptop])
    try await world.start()
    let workbench = world.workbench!
    workbench.select(host: studio.id, session: nil)
    XCTAssertTrue(workbench.canChooseHost)
    try type("hello", in: workbench)

    workbench.chooseHost(laptop.id)
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: laptop.id, session: nil))
    XCTAssertEqual(workbench.current?.hostLabel, "Laptop")
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "hello", "the words move with it")
    XCTAssertEqual(workbench.draft(for: PhoneWorkbench.Selection(host: studio.id, session: nil)), "")

    let sent = await workbench.send()
    XCTAssertEqual(sent, .sent)
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: laptop.id, session: 99), "the chat starts on the Mac chosen")
    XCTAssertEqual(world.creations.places, [.home])
  }

  func testOnlyANewChatMovesAndOnlyToAnotherOnlineMac() async throws {
    let studio = Mac("Studio", online: true, sessions: [1])
    let old = Mac("Old", online: false)
    let world = PhoneWorld([studio, old])
    try await world.start()
    let workbench = world.workbench!
    XCTAssertEqual(workbench.selection?.host, studio.id, "the online Mac")
    workbench.chooseHost(old.id)
    XCTAssertEqual(workbench.selection?.host, studio.id, "an offline Mac cannot take a chat")
    workbench.chooseHost(UUID())
    XCTAssertEqual(workbench.selection?.host, studio.id, "nor a Mac the account does not have")

    workbench.select(session: 1)
    XCTAssertFalse(workbench.canChooseHost, "a chat already going stays on its Mac")
    workbench.chooseHost(old.id)
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: studio.id, session: 1))

    let alone = PhoneWorld([Mac("Only", online: true)])
    try await alone.start()
    XCTAssertFalse(alone.workbench.canChooseHost, "with one Mac there is nothing to choose")
  }

  func testNoChatCanStartWhenEveryMacIsOffline() async throws {
    let world = PhoneWorld([Mac("Old", online: false, sessions: [1])])
    try await world.start()
    let workbench = world.workbench!
    XCTAssertNil(workbench.newChatHost)
    try type("hello", in: workbench)
    let sent = await workbench.send()
    XCTAssertEqual(sent, .failed)
    XCTAssertEqual(workbench.current?.failure, "Old is offline.")
    XCTAssertTrue(world.creations.places.isEmpty)
  }

  func testTheMenuListsTheOpenMacsChatsAsTheyAreNowNotAsTheyWereListed() async throws {
    let online = Mac("New", online: true, sessions: [1])
    let other = Mac("Other", online: true, sessions: [5])
    let world = PhoneWorld([online, other])
    try await world.start()
    let workbench = world.workbench!
    workbench.select(host: online.id, session: nil)
    try type("hello", in: workbench)
    _ = await workbench.send()
    let listedOnline = try XCTUnwrap(workbench.hosts.hosts.first { $0.hostId == online.id })
    let listedOther = try XCTUnwrap(workbench.hosts.hosts.first { $0.hostId == other.id })
    XCTAssertEqual(Set(workbench.sessions(of: listedOnline).map(\.sessionId)), [1, 99], "the chat just made is listed")
    XCTAssertEqual(listedOnline.sessions.map(\.sessionId), [1], "the listing itself has not caught up")
    XCTAssertEqual(workbench.sessions(of: listedOther).map(\.sessionId), [5], "other Macs are as listed")
  }

  func testAMacWithoutChatsStillLandsOnABlankOneAndNoMacMeansNothingToOpen() async throws {
    let world = PhoneWorld([Mac("Empty", online: true)])
    try await world.start()
    XCTAssertTrue(world.workbench.isDrafting)
    XCTAssertEqual(world.made.count, 1)
    let none = PhoneWorld([])
    try await none.start()
    XCTAssertNil(none.workbench.selection)
    XCTAssertTrue(none.made.isEmpty)
  }

  func testOpeningAnotherMacClosesTheFirstAndSameMacJustSwitchesSession() async throws {
    let a = Mac("A", online: true, sessions: [1, 2])
    let b = Mac("B", online: false, sessions: [5])
    let world = PhoneWorld([a, b])
    try await world.start()
    let workbench = world.workbench!
    let first = try XCTUnwrap(workbench.current)

    workbench.select(session: 2)
    XCTAssertEqual(workbench.selection?.session, 2)
    XCTAssertTrue(workbench.current === first, "the same Mac stays open")
    XCTAssertEqual(first.selectedSessionID, 2)
    let channel = try await world.transport.channel()
    try await eventually { first.historyStates[2] == .loaded(records: 0, hasOlder: false) }

    workbench.select(host: b.id, session: 5)
    XCTAssertFalse(workbench.current === first)
    XCTAssertEqual(workbench.current?.hostLabel, "B")
    try await eventually { channel.closes(of: 2) == 1 }
    try await eventually { workbench.current?.historyStates[5] == .loaded(records: 0, hasOlder: false) }
    XCTAssertEqual(world.made.count, 2)
    XCTAssertEqual(world.transport.connects, 1, "one socket for every Mac")
  }

  func testAnUnknownMacIsNotOpenedAndClosingForgetsEverything() async throws {
    let a = Mac("A", online: true, sessions: [1])
    let world = PhoneWorld([a])
    try await world.start()
    let workbench = world.workbench!
    workbench.select(host: UUID(), session: 1)
    XCTAssertEqual(workbench.selection?.host, a.id, "nothing changed")
    workbench.close()
    XCTAssertNil(workbench.selection)
    XCTAssertNil(workbench.current)
  }

  // MARK: - Following the account

  func testTheAccountsChangesReachTheOpenMac() async throws {
    var a = Mac("A", online: true, sessions: [1])
    let world = PhoneWorld([a])
    try await world.start()
    let workbench = world.workbench!
    workbench.select(session: 1)
    let channel = try await world.transport.channel()
    try await eventually { workbench.current?.historyStates[1] != nil && workbench.current?.historyStates[1] != .loading }

    channel.notify("axo.client.sessions", Wire.sessionsNotice(host: a.id, [
      Wire.session(host: a.id, id: 1, name: "Renamed", status: "working", createdAt: 1),
      Wire.session(host: a.id, id: 2, name: "Two", createdAt: 2),
    ]))
    try await eventually { workbench.current?.sessions.map(\.displayName) == ["Renamed", "Two"] }
    XCTAssertEqual(workbench.current?.chats[1]?.activity, .working)

    channel.notify("axo.client.session.records", Wire.recordsNotice(1, [said(1, "hi", role: "assistant")]))
    try await eventually { workbench.current?.chats[1]?.messages.map(\.text) == ["hi"] }
    try await eventually { channel.acks(of: 1) == [1] }

    channel.notify("axo.client.session.progress", Wire.progressNotice(1, slot: "question", #"{"kind":"input","title":"Name?"}"#))
    try await eventually { workbench.current?.chat(1).transcript?.question?.title == "Name?" }

    a.online = false
    channel.notify("axo.client.hosts", #"{"hosts":[\#(a.hostJSON)]}"#)
    try await eventually { workbench.current?.status == .offline }
  }

  func testAnArchivedChatLeavesTheList() async throws {
    let a = Mac("A", online: true, sessions: [1, 2])
    let world = PhoneWorld([a])
    try await world.start()
    let channel = try await world.transport.channel()
    channel.notify("axo.client.sessions", Wire.sessionsNotice(host: a.id, [Wire.session(host: a.id, id: 2, name: "Two", archived: true)]))
    try await eventually { world.workbench.hosts.hosts.first?.sessions.map(\.sessionId) == [1] }
  }

  func testAMacThatLeftTheAccountCloses() async throws {
    let a = Mac("A", online: true, sessions: [1])
    let world = PhoneWorld([a])
    try await world.start()
    XCTAssertNotNil(world.workbench.current)
    let channel = try await world.transport.channel()
    channel.notify("axo.client.hosts", #"{"hosts":[]}"#)
    try await eventually { world.workbench.current == nil }
  }

  func testAMacThatComesBackAsANewRunIsOpenedAfreshOnTheSameChat() async throws {
    var a = Mac("A", online: true, sessions: [1])
    let world = PhoneWorld([a])
    try await world.start()
    let workbench = world.workbench!
    workbench.select(session: 1)
    let old = try XCTUnwrap(workbench.current)
    a.generation = UUID()
    let channel = try await world.transport.channel()
    channel.notify("axo.client.hosts", #"{"hosts":[\#(a.hostJSON)]}"#)
    try await eventually { workbench.current?.reference.hostGeneration == a.generation }
    XCTAssertFalse(workbench.current === old)
    XCTAssertEqual(workbench.selection?.session, 1)
  }

  func testRefreshListsAMacPairedAMomentAgo() async throws {
    let a = Mac("A", online: true)
    let world = PhoneWorld([a])
    try await world.start()
    let laptop = Mac("Laptop", online: true)
    world.transport.listing = Mac.listing([a, laptop])
    await world.workbench.refresh()
    XCTAssertEqual(Set(world.workbench.hosts.hosts.map(\.label)), ["A", "Laptop"])
  }

  func testADroppedSocketReconnectsAndTheOpenChatReadsOnFromWhatItHolds() async throws {
    let a = Mac("A", online: true, sessions: [1])
    let world = PhoneWorld([a], answers: false)
    try await world.start()
    let workbench = world.workbench!
    workbench.select(session: 1)
    let first = try await world.transport.channel(number: 1)
    let open = try await first.nextRequest("axo.client.session.open")
    first.reply(to: open.id, result: Wire.opened(epoch: 3, [said(4, "q")]))
    try await eventually { workbench.current?.chats[1]?.messages.count == 1 }

    first.close()
    let second = try await world.transport.channel(number: 2)
    try await eventually { workbench.link == .connected }
    let reopen = try await second.nextRequest("axo.client.session.open")
    XCTAssertEqual(reopen.method, "axo.client.session.open")
    XCTAssertEqual((reopen.params["have"] as? [String: Any])?["cursor"] as? Int, 4)
    second.reply(to: reopen.id, result: Wire.opened(epoch: 3, [said(5, "missed", role: "assistant")]))
    try await eventually { workbench.current?.chats[1]?.messages.map(\.text) == ["q", "missed"] }
    workbench.stop()
  }

  func testTheBackgroundLetsTheSocketGoAndTheForegroundComesBack() async throws {
    let world = PhoneWorld([Mac("A", online: true)], workspaces: workspaces(["Project"]))
    try await world.start()
    let workbench = world.workbench!
    try await eventually { workbench.current?.workspaceList.isEmpty == false }
    workbench.suspend()
    XCTAssertEqual(workbench.link, .suspended)
    XCTAssertEqual(workbench.current?.link, .suspended)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(world.transport.connects, 1, "no reconnecting in the background")
    XCTAssertEqual(workbench.link, .suspended, "letting go on purpose is not a loss")

    await workbench.resume()
    try await eventually { workbench.link == .connected }
    XCTAssertEqual(world.transport.connects, 2)
    workbench.stop()
  }

  func testBecomingActiveWithoutHavingBeenAwayDoesNothing() async throws {
    let world = PhoneWorld([Mac("A", online: true)])
    try await world.start()
    await world.workbench.resume()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(world.transport.connects, 1)
  }

  func testARefusedSocketSignsThePhoneOut() async throws {
    let world = PhoneWorld([Mac("A", online: true)])
    world.transport.refuse(RelayError.signInRequired)
    await world.workbench.start()
    XCTAssertEqual(world.account.state, .signedOut)
  }
}
