import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

@MainActor
final class HostWorkbenchModelTests: XCTestCase {
  // MARK: - Reading a chat

  func testOpeningAChatReadsItsNewestWindowAndItsNewRecordsFollow() async throws {
    let world = HostWorld()
    let request = try await world.open(1, answering: Wire.opened([said(2, "q"), said(3, "a", role: "assistant")], older: 2))
    XCTAssertEqual(request.method, "axo.client.session.open")
    XCTAssertEqual(request.params["sessionId"] as? String, SessionID.fixture(1).rawValue)
    XCTAssertEqual(request.params["hostId"] as? String, world.host.hostId.uuidString.lowercased())
    XCTAssertEqual((request.params["window"] as? [String: Any])?["last"] as? Int, HostWorkbenchModel.historyPageSize)
    XCTAssertNil(request.params["have"] as? [String: Any], "nothing is held yet")
    XCTAssertEqual(world.model.chats[1]?.messages.map(\.text), ["q", "a"])
    XCTAssertEqual(world.model.historyStates[1], .loaded(records: 2, hasOlder: true))

    world.model.receive(records: [said(4, "live", role: "assistant")], epoch: 1, cursor: 4, in: 1)
    XCTAssertEqual(world.model.chats[1]?.messages.map(\.text), ["q", "a", "live"])
    let channel = try await world.channel()
    try await eventually { channel.acks(of: 1) == [4] }
  }

  func testRecordsOfAChatThatIsNotOpenAreAcknowledgedButNotShown() async throws {
    let world = HostWorld(sessions: [(1, "One"), (2, "Two")])
    _ = try await world.open(1, answering: Wire.opened([said(1, "q")]))
    world.model.receive(records: [said(1, "elsewhere")], epoch: 1, cursor: 1, in: 2)
    XCTAssertNil(world.model.chats[2])
    let channel = try await world.channel()
    try await eventually { channel.acks(of: 2) == [1] }
  }

  func testOpeningAnotherChatLetsGoOfTheOneBefore() async throws {
    let world = HostWorld(sessions: [(1, "One"), (2, "Two")])
    _ = try await world.open(1, answering: Wire.opened([said(1, "q")]))
    _ = try await world.open(2, answering: Wire.opened([said(1, "other")]))
    let channel = try await world.channel()
    try await eventually { channel.closes(of: 1) == 1 }
    world.model.receive(records: [said(2, "late")], epoch: 1, cursor: 2, in: 1)
    XCTAssertEqual(world.model.chats[1]?.messages.map(\.text), ["q"], "a closed chat takes no more records")
  }

  func testOlderPagesAreReadOnDemandAndGoBeforeWhatIsShown() async throws {
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened([said(3, "q2")], older: 3))
    let loading = Task { await world.model.loadOlderHistory(of: 1) }
    let channel = try await world.channel()
    let request = try await channel.nextRequest()
    XCTAssertEqual(request.method, "axo.client.session.older")
    XCTAssertEqual(request.params["before"] as? Int, 3)
    channel.reply(to: request.id, result: Wire.olderPage([said(1, "q"), said(2, "a", role: "assistant")]))
    await loading.value
    XCTAssertEqual(world.model.chats[1]?.messages.map(\.text), ["q", "a", "q2"])
    XCTAssertEqual(world.model.historyStates[1], .loaded(records: 3, hasOlder: false))
    await world.model.loadOlderHistory(of: 1)
    XCTAssertFalse(channel.hasRequest, "the beginning has nothing older")
  }

  func testOpeningAgainReadsOnFromWhatIsHeld() async throws {
    // After a reconnection the open chat opens again, while the person may be reading older pages.
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened(epoch: 7, [said(5, "q")], older: 5))
    let request = try await world.open(1, answering: Wire.opened(epoch: 7, [said(6, "a", role: "assistant")]))
    let have = try XCTUnwrap(request.params["have"] as? [String: Any])
    XCTAssertEqual(have["epoch"] as? Int, 7)
    XCTAssertEqual(have["cursor"] as? Int, 5)
    XCTAssertEqual(world.model.chats[1]?.messages.map(\.text), ["q", "a"])
    XCTAssertEqual(world.model.historyStates[1], .loaded(records: 2, hasOlder: true), "what is older is still known")
  }

  func testABatchThatSkipsAheadOpensAgainFromWhatIsHeld() async throws {
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened([said(1, "q")]))
    world.model.receive(records: [said(5, "far")], epoch: 1, cursor: 5, in: 1)
    let channel = try await world.channel()
    let request = try await channel.nextRequest()
    XCTAssertEqual(request.method, "axo.client.session.open")
    XCTAssertEqual((request.params["have"] as? [String: Any])?["cursor"] as? Int, 1)
    channel.reply(to: request.id, result: Wire.opened([said(2, "two"), said(3, "three")]))
    try await eventually { world.model.chats[1]?.messages.count == 3 }
  }

  func testACutBackDropsWhatCameAfter() async throws {
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened([said(1, "q"), said(2, "gone")]))
    world.model.receive(resetTo: 1, epoch: 2, in: 1)
    XCTAssertEqual(world.model.chats[1]?.messages.map(\.text), ["q"])
    world.model.receive(records: [said(2, "new")], epoch: 2, cursor: 2, in: 1)
    XCTAssertEqual(world.model.chats[1]?.messages.map(\.text), ["q", "new"], "the new epoch's records follow")
  }

  func testWhatIsInProgressWhenOpenedShows() async throws {
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened(
      [said(1, "q")], progress: #"[{"slot":"question","snapshot":{"kind":"confirm","title":"Go?"}}]"#))
    XCTAssertEqual(world.model.chat(1).transcript?.question, ChatQuestion(kind: .confirm, title: "Go?"))
  }

  func testAFailedOlderPageKeepsWhatIsShownAndCanBeRetried() async throws {
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened([said(2, "q2")], older: 2))
    let loading = Task { await world.model.loadOlderHistory(of: 1) }
    let channel = try await world.channel()
    channel.reply(to: try await channel.nextRequest().id, error: -32603, message: "Internal error")
    await loading.value
    XCTAssertEqual(world.model.chats[1]?.messages.map(\.text), ["q2"])
    XCTAssertEqual(world.model.historyStates[1], .loaded(records: 1, hasOlder: true))
    XCTAssertNotNil(world.model.failure)
  }

  func testAFailedOpenIsReportedAndSignsOutOnlyForARefusedSession() async throws {
    let world = HostWorld()
    let opening = Task { await world.model.loadHistory(of: 1) }
    let channel = try await world.channel()
    channel.reply(to: try await channel.nextRequest().id, error: -32004, message: "Resource not found")
    await opening.value
    guard case .failed = world.model.historyStates[1] else { return XCTFail("\(String(describing: world.model.historyStates[1]))") }
    XCTAssertEqual(world.account.state, .signedIn)

    let refusing = ScriptedTransport()
    refusing.refuse(RelayError.signInRequired)
    let refused = HostWorld(transport: refusing)
    await refused.model.loadHistory(of: 1)
    XCTAssertEqual(refused.account.state, .signedOut)
  }

  /// Whether reading `read` is invalidated by `change`, as a SwiftUI view reading it would be.
  private func invalidates(_ read: () -> Void, by change: () -> Void) -> Bool {
    final class Flag: @unchecked Sendable { var raised = false }
    let flag = Flag()
    withObservationTracking(read) { flag.raised = true }
    change()
    return flag.raised
  }

  func testProgressInOneChatDoesNotRedrawAnother() async throws {
    let world = HostWorld(sessions: [(1, "One"), (2, "Two")])
    _ = try await world.open(1, answering: Wire.opened([said(1, "q")]))
    _ = try await world.open(2, answering: Wire.opened([said(1, "q")]))
    let open = world.model.chat(2)
    func reply(in id: SessionID) {
      world.model.receive(progress: "message", snapshot: jsonValue(#"{"message":{"role":"assistant","content":"hm"}}"#), in: id)
    }
    // Everything a conversation reads, as it reads it.
    let readOpenChat = { _ = (open.transcript, open.history, open.pending, open.isStopping) }
    XCTAssertFalse(invalidates(readOpenChat, by: { reply(in: 1) }), "another chat's reply is not this chat's news")
    XCTAssertTrue(invalidates(readOpenChat, by: { reply(in: 2) }), "its own is")
    XCTAssertEqual(world.model.chat(2).transcript?.live.map(\.text), ["hm"])
  }

  // MARK: - The listing

  func testStartsWithTheHostsSessionsInOrderAndSelectsNoneOnItsOwn() {
    let world = HostWorld(sessions: [(1, "One"), (2, "Two")])
    XCTAssertEqual(world.model.sessions.map(\.sessionId), [1, 2])
    world.model.selectedSessionID = nil
    world.model.update([RemoteSession(ClientSession(
      hostId: world.host.hostId, sessionId: 3, metadata: SessionMetadata(name: "Three", createdAt: 3)))])
    XCTAssertNil(world.model.selectedSessionID, "a new Session must not pull the screen off a blank chat")
    XCTAssertEqual(world.model.sessions.map(\.sessionId), [1, 2, 3])
  }

  func testAListingReplacesTheSessionsAndAChatNoLongerListedIsNotOpen() {
    let world = HostWorld()
    let renamed = RemoteSession(ClientSession(hostId: world.host.hostId, sessionId: 1, metadata: SessionMetadata(name: "Renamed")))
    world.model.update([renamed])
    XCTAssertEqual(world.model.sessions.map(\.displayName), ["Renamed"])

    let two = RemoteSession(ClientSession(hostId: world.host.hostId, sessionId: 2, metadata: SessionMetadata(name: "Two")))
    world.model.adopt(listing: RemoteHost(
      ClientHost(hostId: world.host.hostId, hostGeneration: world.host.hostGeneration, label: "Studio", online: false), sessions: [two]))
    XCTAssertEqual(world.model.sessions.map(\.sessionId), [2])
    XCTAssertEqual(world.model.status, .offline)
    XCTAssertNil(world.model.selectedSessionID, "a Session no longer listed is not open, and nothing else opens in its place")
  }

  func testAnotherHostsListingAndSessionsAreIgnored() {
    let world = HostWorld()
    world.model.adopt(listing: RemoteHost(ClientHost(hostId: UUID(), hostGeneration: UUID(), label: "Other", online: false), sessions: []))
    world.model.update([RemoteSession(ClientSession(hostId: UUID(), sessionId: 9, metadata: SessionMetadata()))])
    XCTAssertEqual(world.model.status, .online)
    XCTAssertEqual(world.model.sessions.map(\.sessionId), [1])
  }

  func testWorkingIsWhatTheListingSays() async throws {
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened([said(1, "q")]))
    func listed(_ status: RemoteSessionStatus) {
      world.model.update([RemoteSession(ClientSession(
        hostId: world.host.hostId, sessionId: 1, metadata: SessionMetadata(name: "One", createdAt: 1), status: status))])
    }
    listed(.working)
    XCTAssertEqual(world.model.chats[1]?.activity, .working)
    listed(.ready)
    XCTAssertEqual(world.model.chats[1]?.activity, .idle)
  }

  // MARK: - Actions

  func testAPromptGoesToTheSelectedSessionsAgentAndIsAcceptedOnlyWhenTheHostSaysSo() async throws {
    let world = HostWorld(sessions: [(4, "Four")])
    let sending = Task { await world.model.sendPrompt("  run the tests \n") }
    let channel = try await world.channel()
    let sent = try await channel.nextRequest()
    XCTAssertEqual(sent.rpcMethod, "axo.client.command")
    XCTAssertEqual(sent.hostID, world.host.hostId.uuidString.lowercased())
    XCTAssertEqual(sent.method, "axo.remote.session.prompt")
    XCTAssertEqual(sent.params["sessionId"] as? String, SessionID.fixture(4).rawValue)
    XCTAssertEqual(sent.params["text"] as? String, "run the tests", "trimmed, nothing else changed")
    channel.reply(to: sent.id, result: #"{"accepted":true}"#)
    let accepted = await sending.value
    XCTAssertEqual(accepted, .accepted)
    XCTAssertNil(world.model.failure)
    XCTAssertNil(world.model.chats[4], "the agent's own record brings the prompt back; nothing is invented here")
  }

  /// Sends `text` and has the host accept it; returns its commandId.
  @discardableResult
  private func sendAccepted(_ text: String, in world: HostWorld) async throws -> String {
    let sending = Task { await world.model.sendPrompt(text) }
    let channel = try await world.channel()
    let request = try await channel.nextRequest()
    channel.reply(to: request.id, result: #"{"accepted":true}"#)
    _ = await sending.value
    return try XCTUnwrap(request.params["commandId"] as? String)
  }

  func testASentMessageShowsAsPendingUntilTheAgentRecordsItThenOnlyTheRecordRemains() async throws {
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened([]))
    let sending = Task { await world.model.sendPrompt("  run the tests ") }
    let channel = try await world.channel()
    let request = try await channel.nextRequest()
    XCTAssertEqual(world.model.pendingPrompts[1]?.map(\.state), [.sending], "shown at once, before the Mac answers")
    let commandId = try XCTUnwrap(request.params["commandId"] as? String)
    XCTAssertEqual(commandId, world.model.pendingPrompts[1]?.first?.id.uuidString.lowercased())
    channel.reply(to: request.id, result: #"{"accepted":true}"#)
    _ = await sending.value
    XCTAssertEqual(world.model.pendingPrompts[1]?.map(\.text), ["run the tests"])
    XCTAssertEqual(world.model.pendingPrompts[1]?.map(\.state), [.sent])

    world.model.receive(records: [said(1, "run the tests")], epoch: 1, cursor: 1, in: 1)
    XCTAssertEqual(world.model.pendingPrompts[1]?.count, 1, "the same words typed on the Mac are not this message")
    world.model.receive(records: [receipt(2, commandId)], epoch: 1, cursor: 2, in: 1)
    XCTAssertEqual(world.model.pendingPrompts[1]?.count, 1, "its receipt alone does not show it yet")
    world.model.receive(records: [said(3, "run the tests")], epoch: 1, cursor: 3, in: 1)
    XCTAssertNil(world.model.pendingPrompts[1])
    XCTAssertEqual(world.model.chats[1]?.messages.filter { $0.role == .user }.count, 2, "each shown once")
  }

  func testAMessageSentWhileTheAgentWorksIsQueuedAndEachIsRetiredByItsOwnReceipt() async throws {
    let world = HostWorld()
    _ = try await world.open(1, answering: Wire.opened([]))
    world.model.update([RemoteSession(ClientSession(
      hostId: world.host.hostId, sessionId: 1, metadata: SessionMetadata(name: "One", createdAt: 1), status: .working))])
    let first = try await sendAccepted("same", in: world)
    let second = try await sendAccepted("same", in: world)
    XCTAssertEqual(world.model.pendingPrompts[1]?.map(\.state), [.queued, .queued])
    world.model.receive(records: [receipt(1, second), said(2, "same")], epoch: 1, cursor: 2, in: 1)
    XCTAssertEqual(world.model.pendingPrompts[1]?.map { $0.id.uuidString.lowercased() }, [first])
    world.model.receive(records: [receipt(3, first), said(4, "same")], epoch: 1, cursor: 4, in: 1)
    XCTAssertNil(world.model.pendingPrompts[1])
  }

  func testOlderHistoryArrivingDoesNotRetireAPendingMessage() async throws {
    let world = HostWorld()
    let asked = try await sendAccepted("ask", in: world)
    _ = try await world.open(1, answering: Wire.opened([receipt(2, asked), said(3, "ask")], older: 2))
    XCTAssertNil(world.model.pendingPrompts[1], "the newest window is news: it has the message")
    try await sendAccepted("ask", in: world)
    let loading = Task { await world.model.loadOlderHistory(of: 1) }
    let channel = try await world.channel()
    channel.reply(to: try await channel.nextRequest().id, result: Wire.olderPage([said(1, "ask")]))
    await loading.value
    XCTAssertEqual(world.model.pendingPrompts[1]?.count, 1, "an older page saying the same words is not the new message")
  }

  func testARefusedPromptIsNotAccepted() async throws {
    let world = HostWorld()
    let sending = Task { await world.model.sendPrompt("hello") }
    let channel = try await world.channel()
    channel.reply(to: try await channel.nextRequest().id, error: -32004, message: "Resource not found")
    let accepted = await sending.value
    XCTAssertEqual(accepted, .notSent)
    XCTAssertEqual(world.model.failure, "Not sent: Resource not found")
    XCTAssertNil(world.model.pendingPrompts[1])
  }

  func testAPromptForAnOfflineMacIsNotSentAndNotQueued() async throws {
    let world = HostWorld()
    let sending = Task { await world.model.sendPrompt("hello") }
    let channel = try await world.channel()
    channel.reply(to: try await channel.nextRequest().id, error: -32005, message: "Host offline")
    let outcome = await sending.value
    XCTAssertEqual(outcome, .notSent)
    XCTAssertEqual(world.model.failure, "Not sent: Studio is offline. Your message is still in the box.")
  }

  func testAStaleHostIsReportedButIsNotAnAccessProblem() async throws {
    let world = HostWorld()
    let typing = Task { await world.model.sendPrompt("x") }
    let channel = try await world.channel()
    channel.reply(to: try await channel.nextRequest().id, error: -32002, message: "Stale host")
    _ = await typing.value
    XCTAssertEqual(world.model.failure, "Not sent: Stale host")
    XCTAssertEqual(world.account.state, .signedIn, "a stale host is not a sign-in problem")
  }

  func testARefusedConnectionSignsThePhoneOut() async throws {
    let refusing = ScriptedTransport()
    refusing.refuse(RelayError.signInRequired)
    let world = HostWorld(transport: refusing)
    _ = await world.model.sendPrompt("x")
    XCTAssertEqual(world.account.state, .signedOut)
    XCTAssertEqual(world.model.failure, "Not sent: Sign in to continue.")
  }

  func testNothingIsSentWithoutTextOrASession() async throws {
    let world = HostWorld()
    let blank = await world.model.sendPrompt("  \n ")
    XCTAssertEqual(blank, .notSent)
    let empty = HostWorld(sessions: [])
    let nowhere = await empty.model.sendPrompt("hello")
    XCTAssertEqual(nowhere, .notSent)
    XCTAssertEqual(world.transport.connects + empty.transport.connects, 0)
  }

  func testANewChatIsListedAtOnceAndOpened() async throws {
    let world = HostWorld()
    world.model.selectedSessionID = nil
    let creating = Task { await world.model.createChat(in: .home) }
    let channel = try await world.channel()
    let create = try await channel.nextRequest()
    XCTAssertEqual(create.method, "axo.remote.session.create")
    channel.reply(to: create.id, result: #"{"session":\#(sessionJSON(host: world.host.hostId, id: 5, name: "New", shells: []))}"#)
    _ = await creating.value
    XCTAssertEqual(world.model.selectedSessionID, 5)
    let open = try await channel.nextRequest()
    XCTAssertEqual(open.method, "axo.client.session.open")
    channel.reply(to: open.id, result: Wire.opened(epoch: nil, []))
    // A listing that does not have it yet keeps it.
    world.model.adopt(listing: world.host)
    XCTAssertTrue(world.model.sessions.contains { $0.sessionId == 5 })
  }
}
