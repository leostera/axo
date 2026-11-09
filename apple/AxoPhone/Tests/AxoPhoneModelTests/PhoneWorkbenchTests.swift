import CryptoKit
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
  private var files: [[String]] = []
  /// The names of the files each prompt carried, in order.
  var attached: [[String]] { lock.withLock { files } }
  func record(attached names: [String]) { lock.withLock { files.append(names) } }
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
    _ macs: [Mac], createsSession: SessionID? = 99, refusesPrompts: Bool = false,
    answers: Bool = true,
    uploadAsset: @escaping @Sendable (Data, String, String) async throws -> Attachment = { _, _, _ in
      throw AxoClientError.invalidResponse("no uploads in this test")
    }
  ) {
    transport = ScriptedTransport(listing: Mac.listing(macs))
    feed = AccountConnection(transport: transport, clientID: ClientID(rawValue: "test-client")!)
    if answers { transport.responder = Self.responder(createsSession: createsSession, refusesPrompts: refusesPrompts, creations: creations) }
    let feed = feed
    let account = account
    workbench = PhoneWorkbench(
      hosts: HostsModel(profile: NoProfile()), feed: feed, account: account, reconnectDelays: [.milliseconds(10)],
      uploadAsset: uploadAsset
    ) { [unowned self] remote in
      let model = HostWorkbenchModel(
        host: remote, connection: HostConnection(account: feed, host: remote.reference), feed: feed, account: account)
      self.made.append(model)
      return model
    }
    workbench.device = SoftwareDeviceSigner()
  }

  /// Answers the Macs' commands and opens every chat empty.
  private static func responder(
    createsSession: SessionID?, refusesPrompts: Bool, creations: Creations
  ) -> @Sendable (ScriptedRequest) -> ScriptedReply? {
    return { request in
      switch request.method {
      case "axo.client.session.open": return .result(Wire.opened(epoch: nil, []))
      case "axo.remote.session.create":
        let target = request.params["target"] as? [String: Any]
        guard let session = createsSession, let host = (target?["hostId"] as? String).flatMap(UUID.init) else {
          return .error(-32003, "Operation failed")
        }
        if let like = (request.params["like"] as? String).flatMap(SessionID.init(rawValue:)) {
          creations.record(.beside(like))
        } else {
          creations.record(.home)
        }
        let number = Int(session.rawValue.prefix(8), radix: 16)!
        return .result(#"{"session":\#(sessionJSON(host: host, id: number, name: "New chat", shells: []))}"#)
      case "axo.remote.session.prompt":
        guard !refusesPrompts else { return .error(-32003, "Operation failed") }
        creations.record(prompt: request.params["text"] as? String ?? "")
        let files = request.params["attachments"] as? [[String: Any]] ?? []
        creations.record(attached: files.compactMap { $0["name"] as? String })
        return .result(#"{"accepted":true}"#)
      case "axo.remote.session.key": return .result(#"{"accepted":true}"#)
      case "axo.client.host.rename":
        // An empty name goes back to the Mac's own, which these Macs call "Own name".
        let name = request.params["name"] as? String ?? ""
        if name == "refuse" { return .error(-32602, "Invalid params") }
        return .result(#"{"label":"\#(name.isEmpty ? "Own name" : name)"}"#)
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

  func testAChatStartsInTheMacsHomeFolderWithItsFirstMessage() async throws {
    let offline = Mac("Old", online: false, sessions: [1])
    let online = Mac("New", online: true)
    let world = PhoneWorld([offline, online])
    try await world.start()
    let workbench = world.workbench!
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: online.id, session: nil), "a blank chat on the Mac that is online")
    try type("hello", in: workbench)
    let sent = await workbench.send()
    XCTAssertEqual(sent, .sent)
    XCTAssertEqual(workbench.selection, PhoneWorkbench.Selection(host: online.id, session: 99))
    XCTAssertEqual(workbench.current?.selectedSession?.displayName, "New chat")
    XCTAssertEqual(world.creations.places, [.home], "a new chat starts in the Mac's home folder")
    XCTAssertEqual(world.creations.prompts, ["hello"], "the first message goes to the chat it created")
    XCTAssertFalse(workbench.isDrafting)
    XCTAssertEqual(workbench.draft(for: PhoneWorkbench.Selection(host: online.id, session: nil)), "", "the blank chat's box is empty again")
    XCTAssertEqual(workbench.draft(for: try XCTUnwrap(workbench.selection)), "")
    XCTAssertEqual(workbench.current?.pendingPrompts[99]?.map(\.text), ["hello"], "shown until the agent records it")
    XCTAssertEqual(workbench.current?.pendingPrompts[99]?.first?.state, .sent)
  }

  func testAChatCanStartBesideAnotherInstead() async throws {
    let online = Mac("New", online: true, sessions: [1])
    let world = PhoneWorld([online])
    try await world.start()
    let workbench = world.workbench!
    try type("hello", in: workbench)
    let sent = await workbench.send(in: .beside(1))
    XCTAssertEqual(sent, .sent)
    XCTAssertEqual(world.creations.places, [.beside(1)])
    XCTAssertEqual(world.creations.prompts, ["hello"])
    XCTAssertEqual(workbench.selection?.session, 99)
    try type("more", in: workbench)
    let again = await workbench.send(in: .beside(1))
    XCTAssertEqual(again, .failed, "only a new chat can be placed; an open one already has its folder")
    XCTAssertEqual(world.creations.places.count, 1)
  }

  func testAChatIsOnlyCreatedByItsFirstMessageAndTheChatButtonJustGoesBackToABlankOne() async throws {
    let world = PhoneWorld([Mac("New", online: true, sessions: [1, 2])])
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

  func testAMacIsRenamedForTheAccountAndShownByItsNewNameAtOnce() async throws {
    let studio = Mac("MacBook-Pro-7.local", online: true, sessions: [1])
    let world = PhoneWorld([studio])
    try await world.start()
    let workbench = world.workbench!
    XCTAssertEqual(workbench.current?.hostLabel, "MacBook-Pro-7.local")

    let failure = await workbench.renameHost(studio.id, to: "  Studio  ")
    XCTAssertNil(failure)
    // The relay echoes the name it was sent: sent trimmed.
    XCTAssertEqual(workbench.hosts.hosts.map(\.label), ["Studio"], "the listing shows it before the account's notice")
    XCTAssertEqual(workbench.current?.hostLabel, "Studio", "and so does the open Mac")

    let reset = await workbench.renameHost(studio.id, to: "")
    XCTAssertNil(reset)
    XCTAssertEqual(workbench.current?.hostLabel, "Own name", "an empty name goes back to the Mac's own")

    let refused = await workbench.renameHost(studio.id, to: "refuse")
    XCTAssertNotNil(refused)
    XCTAssertEqual(workbench.current?.hostLabel, "Own name", "a refusal changes nothing")
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

  // MARK: - What the agents ask (RFD0029)

  func testWhatAMacAsksShowsInItsChatUntilSettledAndOnlyOneAnswerGoes() async throws {
    let a = Mac("A", online: true, sessions: [1])
    let world = PhoneWorld([a], answers: false)
    try await world.start()
    let workbench = world.workbench!
    let channel = try await world.transport.channel()
    let id = "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a"
    let asked = #"{"hostId":"\#(a.id.uuidString.lowercased())","elicitation":{"id":"\#(id)","sessionId":"\#((1 as SessionID).rawValue)","kind":"confirm","message":"Delete the branch?","createdAt":1,"expiresAt":2}}"#
    channel.notify("axo.elicitation.requested", asked)
    channel.notify("axo.elicitation.requested", asked)
    try await eventually { workbench.questions(in: 1).map(\.elicitation.message) == ["Delete the branch?"] }
    XCTAssertEqual(workbench.questions.count, 1)
    XCTAssertTrue(workbench.questions(in: 2).isEmpty)

    let answering = Task { await workbench.answer(id, .accept) }
    let request = try await channel.nextRequest("axo.elicitation.resolve")
    XCTAssertEqual(request.params["elicitationId"] as? String, id)
    XCTAssertEqual(request.params["action"] as? String, "accept")
    XCTAssertEqual(request.hostID, a.id.uuidString.lowercased())
    // Signed by this phone's key, over this answer alone (RFD0029).
    let proof = try XCTUnwrap(request.params["device"] as? [String: Any])
    let signer = try XCTUnwrap(workbench.device)
    XCTAssertEqual(proof["key"] as? String, signer.publicKey)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: proof["signature"] as! String)!)
    let key = try P256.Signing.PublicKey(x963Representation: Data(base64Encoded: signer.publicKey)!)
    XCTAssertTrue(key.isValidSignature(signature, for: SoftwareDeviceSigner.message(requestID: id, action: .accept, sealed: nil)))
    XCTAssertEqual(workbench.questions.first?.answering, .accept)
    await workbench.answer(id, .decline)
    channel.reply(to: request.id, result: #"{"resolved":true}"#)
    await answering.value
    XCTAssertFalse(channel.hasRequest, "a second answer never goes")

    // The card goes when the Mac says so, wherever the answer came from.
    XCTAssertEqual(workbench.questions.count, 1)
    channel.notify("axo.elicitation.resolved", #"{"hostId":"\#(a.id.uuidString.lowercased())","id":"\#(id)","sessionId":"\#((1 as SessionID).rawValue)","action":"accept"}"#)
    try await eventually { workbench.questions.isEmpty }
  }

  func testAFormsValuesLeaveOnlySealedAndOnlyToTheKeyFirstSeen() async throws {
    let a = Mac("A", online: true, sessions: [1])
    let world = PhoneWorld([a], answers: false)
    try await world.start()
    let workbench = world.workbench!
    workbench.inputKeyPins = InputKeyPins(defaults: UserDefaults(suiteName: "axo-phone-pins-\(UUID())")!)
    let channel = try await world.transport.channel()
    let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
    func ask(_ id: String, key: String) {
      channel.notify(
        "axo.elicitation.requested",
        #"{"hostId":"\#(a.id.uuidString.lowercased())","elicitation":{"id":"\#(id)","sessionId":"\#((1 as SessionID).rawValue)","kind":"input","askedBy":"computerUse","message":"Fill Password in Safari.","input":{"app":"Safari","window":"Sign in","origin":"https://github.com","fields":[{"id":"f0","label":"Password","kind":"password"}],"key":"\#(key)"},"createdAt":1,"expiresAt":2}}"#)
    }
    let first = "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f60"
    ask(first, key: key)
    try await eventually { workbench.questions.count == 1 }
    let answering = Task { await workbench.answer(first, .accept, values: ["f0": "hunter2"]) }
    let request = try await channel.nextRequest("axo.elicitation.resolve")
    let sealed = request.params["sealed"] as? [String: Any]
    XCTAssertNotNil(sealed?["enc"] as? String)
    XCTAssertFalse("\(request.params)".contains("hunter2"))
    channel.reply(to: request.id, result: #"{"resolved":true}"#)
    await answering.value

    // Another key for the same Mac gets nothing.
    let second = "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f61"
    ask(second, key: P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString())
    try await eventually { workbench.questions.count == 2 }
    await workbench.answer(second, .accept, values: ["f0": "hunter2"])
    XCTAssertFalse(channel.hasRequest)
    XCTAssertEqual(workbench.answerFailure?.contains("key changed"), true)
  }

  func testAnAnswerThatCameTooLateRemovesTheCard() async throws {
    let a = Mac("A", online: true, sessions: [1])
    let world = PhoneWorld([a], answers: false)
    try await world.start()
    let workbench = world.workbench!
    let channel = try await world.transport.channel()
    let id = "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5b"
    channel.notify("axo.elicitation.requested", #"{"hostId":"\#(a.id.uuidString.lowercased())","elicitation":{"id":"\#(id)","sessionId":"\#((1 as SessionID).rawValue)","kind":"confirm","message":"Go?","createdAt":1,"expiresAt":2}}"#)
    try await eventually { workbench.questions.count == 1 }
    let answering = Task { await workbench.answer(id, .accept) }
    let request = try await channel.nextRequest("axo.elicitation.resolve")
    channel.reply(to: request.id, error: -32011, message: "Already answered, or no longer asked")
    await answering.value
    XCTAssertTrue(workbench.questions.isEmpty)
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
    let world = PhoneWorld([Mac("A", online: true)])
    try await world.start()
    let workbench = world.workbench!
    try await eventually { workbench.current != nil }
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

  // MARK: - Attachments (RFD0030)

  func testAPhotoUploadsAtOnceAndTheMessageWaitsForItThenCarriesIt() async throws {
    let studio = Mac("Studio", online: true, sessions: [3])
    let gate = AsyncGate()
    let world = PhoneWorld([studio], uploadAsset: { data, name, mimeType in
      await gate.wait()
      return Attachment(asset: "sha256:" + String(repeating: "ab", count: 32), name: name, mimeType: mimeType, size: data.count)
    })
    try await world.start()
    let workbench = world.workbench!
    workbench.select(session: 3)
    workbench.attach([(data: Data("jpeg".utf8), name: "IMG/0001.jpg", mimeType: "image/jpeg", thumbnail: nil)])
    let selection = try XCTUnwrap(workbench.selection)
    XCTAssertEqual(workbench.attachments(for: selection).map(\.name), ["IMG_0001.jpg"], "a slash never reaches the account")
    XCTAssertFalse(workbench.canSendDraft, "not while the photo is on its way")
    let refused = await workbench.send()
    XCTAssertEqual(refused, .failed)
    await gate.open()
    try await eventually { workbench.canSendDraft }
    let sent = await workbench.send()
    XCTAssertEqual(sent, .sent)
    try await eventually { world.creations.attached.count == 1 }
    XCTAssertEqual(world.creations.attached, [["IMG_0001.jpg"]])
    XCTAssertEqual(world.creations.prompts, [""], "a photo alone is a message")
    XCTAssertTrue(workbench.attachments(for: selection).isEmpty)
  }

  func testAFailedUploadHoldsTheMessageUntilItIsTakenOut() async throws {
    let studio = Mac("Studio", online: true, sessions: [3])
    let world = PhoneWorld([studio], uploadAsset: { _, _, _ in
      throw AppsRefusal(status: 413, message: "The account's assets are full")
    })
    try await world.start()
    let workbench = world.workbench!
    workbench.select(session: 3)
    try type("see attached", in: workbench)
    workbench.attach([(data: Data("x".utf8), name: "a.bin", mimeType: "application/octet-stream", thumbnail: nil)])
    let selection = try XCTUnwrap(workbench.selection)
    try await eventually { workbench.attachments(for: selection).first?.state == .failed("The account's assets are full") }
    XCTAssertFalse(workbench.canSendDraft)
    workbench.detach(try XCTUnwrap(workbench.attachments(for: selection).first?.id))
    XCTAssertTrue(workbench.canSendDraft)
  }

  func testAtMostEightFilesGoInOneMessage() async throws {
    let studio = Mac("Studio", online: true, sessions: [3])
    let world = PhoneWorld([studio], uploadAsset: { data, name, mimeType in
      Attachment(asset: "sha256:" + String(repeating: "cd", count: 32), name: name, mimeType: mimeType, size: data.count)
    })
    try await world.start()
    let workbench = world.workbench!
    workbench.select(session: 3)
    workbench.attach((0..<10).map { (data: Data("\($0)".utf8), name: "\($0).txt", mimeType: "text/plain", thumbnail: nil) })
    XCTAssertEqual(workbench.attachments(for: try XCTUnwrap(workbench.selection)).count, 8)
  }

  func testAttachmentLinesAreShortInTheTranscript() {
    let hex = String(repeating: "ab", count: 32)
    let said = """
      what is in these?

      [Attached image: board.png at /Users/leo/.axo/assets/\(hex)/board.png axo-asset:sha256:\(hex)]

      [Attached file: invoice (final).pdf (application/pdf, 3.0 MB) at /x/invoice (final).pdf axo-asset:sha256:\(hex)]
      """
    XCTAssertEqual(ChatTranscript.attachmentsShown(said), "what is in these?\n\n📎 invoice (final).pdf")
    XCTAssertEqual(Attachment.safeName(".."), "file")
    XCTAssertEqual(Attachment.storedType("image/svg+xml"), "application/octet-stream")
    XCTAssertEqual(Attachment.storedType("text/plain; charset=utf-8"), "text/plain")
  }
}

/// Holds an upload until the test lets it finish.
actor AsyncGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    opened = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}
