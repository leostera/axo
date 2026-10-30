import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

@MainActor
final class HostWorkbenchModelTests: XCTestCase {
  private func make(sessions: [(Int, String, [Int])] = [(1, "One", [10])], history: any PiHistoryLoading = NoHistory()) throws
    -> (HostWorkbenchModel, ScriptedTransport, RemoteHost, AccountSession)
  {
    let id = UUID()
    let json = sessions.map { sessionJSON(host: id, id: $0.0, name: $0.1, shells: $0.2) }
    let remote = try JSONDecoder().decode(
      RemoteHost.self,
      from: Data(
        """
        {"hostId":"\(id.uuidString)","hostGeneration":"\(UUID().uuidString)","label":"Studio",
        "hostKind":"macos","status":"online","stale":false,"lastSeenAt":"2026-10-16T00:00:00Z",
        "sessions":[\(json.joined(separator: ","))]}
        """.utf8))
    let transport = ScriptedTransport()
    let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    let model = HostWorkbenchModel(
      host: remote, connection: HostConnection(transport: transport, host: remote.reference),
      history: history, account: account)
    // A chat is open, as the person's tap on one would have made it.
    model.selectedSessionID = model.sessions.first?.sessionId
    return (model, transport, remote, account)
  }

  private func stored(_ id: Int64, _ sequence: UInt64, role: String, _ text: String, stream: UUID) -> StoredPiEvent {
    try! JSONDecoder().decode(StoredPiEvent.self, from: Data("""
      {"id":\(id),"streamId":"\(stream.uuidString)","sequence":\(sequence),"name":"message.end",
      "data":{"message":{"role":"\(role)","content":"\(text)"}},"receivedAt":1}
      """.utf8))
  }

  func testOpeningAConversationReadsOnlyTheNewestPageAndPutsLiveMessagesAfterIt() async throws {
    let stream = UUID()
    // The relay answers newest first.
    let pages = Pages([
      PiEventPage(events: [stored(3, 3, role: "user", "q2", stream: stream), stored(2, 2, role: "assistant", "a", stream: stream)], next: 2),
      PiEventPage(events: [stored(1, 1, role: "user", "q", stream: stream)], next: nil),
    ])
    let (model, _, host, _) = try make(history: pages)
    model.apply(.piEvent(host: host.reference, sessionID: 1, event: PiEventRecord(
      streamId: stream, sequence: 4, name: "message.end",
      data: try JSONDecoder().decode(JSONValue.self, from: Data(#"{"message":{"role":"assistant","content":"live"}}"#.utf8)))))
    await model.loadHistory(of: 1)
    XCTAssertEqual(model.chats[1]?.messages.map(\.text), ["a", "q2", "live"], "only the newest page, oldest first")
    XCTAssertEqual(model.historyStates[1], .loaded(events: 2, hasOlder: true))
    XCTAssertEqual(pages.cursors, [0], "nothing older is read until it is asked for")
  }

  func testOlderPagesAreReadOnDemandAndGoBeforeWhatIsShown() async throws {
    let stream = UUID()
    let pages = Pages([
      PiEventPage(events: [stored(3, 3, role: "user", "q2", stream: stream), stored(2, 2, role: "assistant", "a", stream: stream)], next: 2),
      PiEventPage(events: [stored(1, 1, role: "user", "q", stream: stream)], next: nil),
    ])
    let (model, _, _, _) = try make(history: pages)
    await model.loadHistory(of: 1)
    await model.loadOlderHistory(of: 1)
    XCTAssertEqual(model.chats[1]?.messages.map(\.text), ["q", "a", "q2"])
    XCTAssertEqual(model.historyStates[1], .loaded(events: 3, hasOlder: false))
    XCTAssertEqual(pages.cursors, [0, 2], "the next page starts before the oldest event shown")
    await model.loadOlderHistory(of: 1)
    XCTAssertEqual(pages.cursors, [0, 2], "the beginning has nothing older")
  }

  func testReadingTheNewestPageAgainKeepsOlderPagesInOrder() async throws {
    // After a reconnection the open chat reads its newest page again, while the person may be
    // reading an older one.
    let stream = UUID()
    let newest = PiEventPage(events: [stored(3, 3, role: "user", "q2", stream: stream), stored(2, 2, role: "assistant", "a", stream: stream)], next: 2)
    let pages = Pages([
      newest,
      PiEventPage(events: [stored(1, 1, role: "user", "q", stream: stream)], next: nil),
      PiEventPage(events: [stored(4, 4, role: "assistant", "a2", stream: stream)] + newest.events, next: 2),
    ])
    let (model, _, _, _) = try make(history: pages)
    await model.loadHistory(of: 1)
    await model.loadOlderHistory(of: 1)
    await model.loadHistory(of: 1)
    XCTAssertEqual(model.chats[1]?.messages.map(\.text), ["q", "a", "q2", "a2"], "older pages stay before the newest")
    XCTAssertEqual(model.historyStates[1], .loaded(events: 4, hasOlder: false), "and what is older is still known")
  }

  func testAFailedOlderPageKeepsWhatIsShownAndCanBeRetried() async throws {
    let stream = UUID()
    let history = FlakyOlder(first: PiEventPage(events: [stored(2, 2, role: "user", "q2", stream: stream)], next: 2))
    let (model, _, _, _) = try make(history: history)
    await model.loadHistory(of: 1)
    await model.loadOlderHistory(of: 1)
    XCTAssertEqual(model.chats[1]?.messages.map(\.text), ["q2"])
    XCTAssertEqual(model.historyStates[1], .loaded(events: 1, hasOlder: true))
    XCTAssertNotNil(model.failure)
  }

  func testAFailedHistoryReadIsReportedAndSignsOutOnlyForARefusedSession() async throws {
    let (model, _, _, account) = try make(history: FailingHistory(error: RelayError.httpStatus(503)))
    await model.loadHistory(of: 1)
    XCTAssertEqual(model.historyStates[1], .failed("The Axo relay answered HTTP 503."))
    XCTAssertEqual(account.state, .signedIn)
    let (refused, _, _, refusedAccount) = try make(history: FailingHistory(error: RelayError.signInRequired))
    await refused.loadHistory(of: 1)
    XCTAssertEqual(refusedAccount.state, .signedOut)
  }

  /// Whether reading `read` is invalidated by `change`, as a SwiftUI view reading it would be.
  private func invalidates(_ read: () -> Void, by change: () -> Void) -> Bool {
    final class Flag: @unchecked Sendable { var raised = false }
    let flag = Flag()
    withObservationTracking(read) { flag.raised = true }
    change()
    return flag.raised
  }

  func testAnEventInOneChatDoesNotRedrawAnother() throws {
    let (model, _, host, _) = try make(sessions: [(1, "One", [10]), (2, "Two", [20])])
    let open = model.chat(2)
    func reply(_ sequence: UInt64, in id: SessionID) {
      model.apply(.piEvent(host: host.reference, sessionID: id, event: PiEventRecord(
        streamId: UUID(), sequence: sequence, name: "agent.start", data: .null)))
    }
    // Everything a conversation reads, as it reads it.
    let readOpenChat = { _ = (open.transcript, open.history, open.pending, open.isStopping) }
    XCTAssertFalse(invalidates(readOpenChat, by: { reply(1, in: 1) }), "another chat's reply is not this chat's news")
    XCTAssertTrue(invalidates(readOpenChat, by: { reply(2, in: 2) }), "its own is")
    XCTAssertEqual(model.chats[2]?.activity, .working)
  }

  func testLivePiEventsReachTheConversationAndARemovedSessionForgetsIt() throws {
    let (model, _, host, _) = try make()
    let record = PiEventRecord(streamId: UUID(), sequence: 1, name: "agent.start", data: .null)
    model.apply(.piEvent(host: host.reference, sessionID: 1, event: record))
    XCTAssertEqual(model.chats[1]?.activity, .working)
    model.apply(.sessionRemoved(host: host.reference, sessionID: 1))
    XCTAssertNil(model.chats[1])
  }

  func testStartsWithTheHostsSessionsInOrderAndSelectsNoneOnItsOwn() throws {
    let (model, _, host, _) = try make(sessions: [(2, "Two", [20]), (1, "One", [10])])
    XCTAssertEqual(model.sessions.map(\.sessionId), [1, 2])
    model.selectedSessionID = nil
    let added = try JSONDecoder().decode(
      RemoteSession.self, from: Data(sessionJSON(host: host.hostId, id: 3, name: "Three", shells: [30]).utf8))
    model.apply(.sessionSnapshot(host: host.reference, session: added))
    XCTAssertNil(model.selectedSessionID, "a new snapshot must not pull the screen off a blank chat")
  }

  func testSnapshotsUpdateAddAndRemoveSessionsAndMoveTheSelection() throws {
    let (model, _, host, _) = try make()
    let renamed = try JSONDecoder().decode(
      RemoteSession.self,
      from: Data(sessionJSON(host: host.hostId, id: 1, name: "Renamed", shells: [10]).utf8))
    model.apply(.sessionSnapshot(host: host.reference, session: renamed))
    XCTAssertEqual(model.sessions.map(\.displayName), ["Renamed"])

    let added = try JSONDecoder().decode(
      RemoteSession.self,
      from: Data(sessionJSON(host: host.hostId, id: 2, name: "Two", shells: [20]).utf8))
    model.apply(.sessionSnapshot(host: host.reference, session: added))
    model.apply(.sessionRemoved(host: host.reference, sessionID: 1))
    XCTAssertEqual(model.sessions.map(\.sessionId), [2])
    XCTAssertNil(model.selectedSessionID, "a removed Session is no longer open, and nothing else opens in its place")
  }

  func testPresenceUpdatesTheStatusAndAnotherHostsEventsAreIgnored() throws {
    let (model, _, host, _) = try make()
    model.apply(.presence(host: host.reference, status: .offline))
    XCTAssertEqual(model.status, .offline)
    let stranger = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())
    model.apply(.presence(host: stranger, status: .online))
    model.apply(.piEvent(host: stranger, sessionID: 1, event: PiEventRecord(streamId: UUID(), sequence: 1, name: "agent.start", data: .null)))
    XCTAssertEqual(model.status, .offline)
    XCTAssertNil(model.chats[1], "another host's events are not ours")
  }

  func testStartNegotiatesAndSubscribesThenAppliesPushedEvents() async throws {
    let (model, transport, host, _) = try make()
    let started = Task { await model.start() }
    let channel = try await transport.channel()
    try await channel.answerNext(result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
    await started.value
    XCTAssertNil(model.failure)
    channel.push(
      #"{"jsonrpc":"2.0","method":"axo.host.event","params":{"subscriptionId":"\#(UUID().uuidString)","event":{"type":"host.data","hostId":"\#(host.hostId.uuidString)","hostGeneration":"\#(host.hostGeneration.uuidString)","event":{"type":"pi.event","sessionId":"00000001-0000-4000-8000-000000000001","piSessionId":"pi-1","streamId":"\#(UUID().uuidString)","sequence":1,"name":"agent.start","data":null}}}}"#
    )
    try await eventually { model.chats[1]?.activity == .working }
    model.stop()
  }

  func testAPromptGoesToTheSelectedSessionsPiAndIsAcceptedOnlyWhenTheHostSaysSo() async throws {
    let (model, transport, _, _) = try make(sessions: [(4, "Four", [40])])
    let sending = Task { await model.sendPrompt("  run the tests \n") }
    let channel = try await transport.channel()
    let sent = try await channel.nextRequest()
    XCTAssertEqual(sent.method, "axo.remote.session.prompt")
    XCTAssertEqual(sent.params["sessionId"] as? String, SessionID.fixture(4).rawValue)
    XCTAssertEqual(sent.params["text"] as? String, "run the tests", "trimmed, nothing else changed")
    channel.reply(to: sent.id, result: #"{"accepted":true}"#)
    let accepted = await sending.value
    XCTAssertEqual(accepted, .accepted)
    XCTAssertNil(model.failure)
    XCTAssertNil(model.chats[4], "Pi's own message brings the prompt back; nothing is invented here")
  }

  private func said(_ text: String, sequence: UInt64, stream: UUID = UUID(), role: String = "user") -> PiEventRecord {
    let json = #"{"message":{"role":"\#(role)","content":[{"type":"text","text":"\#(text)"}]}}"#
    return PiEventRecord(
      streamId: stream, sequence: sequence, name: "message.end",
      data: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
  }

  /// Sends `text` and has the host accept it.
  private func sendAccepted(_ text: String, model: HostWorkbenchModel, transport: ScriptedTransport) async throws {
    let sending = Task { await model.sendPrompt(text) }
    let channel = try await transport.channel()
    let request = try await channel.nextRequest()
    channel.reply(to: request.id, result: #"{"accepted":true}"#)
    _ = await sending.value
  }

  func testASentMessageShowsAsPendingUntilTheAgentRecordsItThenOnlyTheRecordRemains() async throws {
    let (model, transport, host, _) = try make()
    let sending = Task { await model.sendPrompt("  run the tests ") }
    let channel = try await transport.channel()
    let request = try await channel.nextRequest()
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.sending], "shown at once, before the Mac answers")
    channel.reply(to: request.id, result: #"{"accepted":true}"#)
    _ = await sending.value
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.text), ["run the tests"])
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.sent])

    model.apply(.piEvent(host: host.reference, sessionID: 1, event: said("someone else", sequence: 1, role: "assistant")))
    XCTAssertEqual(model.pendingPrompts[1]?.count, 1, "a reply is not the message")
    model.apply(.piEvent(host: host.reference, sessionID: 1, event: said("run the tests", sequence: 2)))
    XCTAssertNil(model.pendingPrompts[1])
    XCTAssertEqual(model.chats[1]?.messages.filter { $0.role == .user }.map(\.text), ["run the tests"], "shown once")
  }

  func testAMessageSentWhileTheAgentWorksIsQueuedAndRecordsRetireTheirOwnWordsFirst() async throws {
    let (model, transport, host, _) = try make()
    model.apply(.piEvent(host: host.reference, sessionID: 1, event: PiEventRecord(streamId: UUID(), sequence: 1, name: "agent.start", data: .null)))
    try await sendAccepted("first", model: model, transport: transport)
    try await sendAccepted("second", model: model, transport: transport)
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.queued, .queued])
    model.apply(.piEvent(host: host.reference, sessionID: 1, event: said("second", sequence: 2)))
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.text), ["first"], "matched by its words, not by order")
    // The agent wrote it down differently: the oldest one the Mac took is the one it means.
    model.apply(.piEvent(host: host.reference, sessionID: 1, event: said("First!", sequence: 3)))
    XCTAssertNil(model.pendingPrompts[1])
  }

  func testOlderHistoryArrivingDoesNotRetireAPendingMessage() async throws {
    let stream = UUID()
    let pages = Pages([
      PiEventPage(events: [stored(2, 2, role: "user", "ask", stream: stream)], next: 2),
      PiEventPage(events: [stored(1, 1, role: "user", "ask", stream: stream)], next: nil),
    ])
    let (model, transport, _, _) = try make(history: pages)
    try await sendAccepted("ask", model: model, transport: transport)
    await model.loadHistory(of: 1)
    XCTAssertNil(model.pendingPrompts[1], "the newest page is news: it has the message")
    try await sendAccepted("ask", model: model, transport: transport)
    await model.loadOlderHistory(of: 1)
    XCTAssertEqual(model.pendingPrompts[1]?.count, 1, "an older page saying the same words is not the new message")
  }

  func testARefusedPromptIsNotAccepted() async throws {
    let (model, transport, _, _) = try make()
    let sending = Task { await model.sendPrompt("hello") }
    let channel = try await transport.channel()
    let sent = try await channel.nextRequest()
    channel.reply(to: sent.id, error: -32004, message: "Resource not found")
    let accepted = await sending.value
    XCTAssertEqual(accepted, .notSent)
    XCTAssertEqual(model.failure, "Not sent: Resource not found")
    XCTAssertNil(model.pendingPrompts[1])
  }

  func testAStaleHostIsReportedButIsNotAnAccessProblem() async throws {
    let (model, transport, _, account) = try make()
    let typing = Task { await model.sendPrompt("x") }
    let channel = try await transport.channel()
    let sent = try await channel.nextRequest()
    channel.reply(to: sent.id, error: -32002, message: "Stale host")
    _ = await typing.value
    XCTAssertEqual(model.failure, "Not sent: Stale host")
    XCTAssertEqual(account.state, .signedIn, "a stale host is not a sign-in problem")
  }

  func testARefusedConnectionSignsThePhoneOut() async throws {
    let id = UUID()
    let remote = try host("Studio", .online, sessions: [sessionJSON(host: id, id: 1, name: "One", shells: [10])])
    let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    let model = HostWorkbenchModel(
      host: remote,
      connection: HostConnection(transport: RefusingTransport(), host: remote.reference),
      history: NoHistory(), account: account)
    model.selectedSessionID = 1
    _ = await model.sendPrompt("x")
    XCTAssertEqual(account.state, .signedOut)
    XCTAssertEqual(model.failure, "Not sent: Sign in to continue.")
  }

  func testNothingIsSentWithoutTextOrASession() async throws {
    let (model, transport, _, _) = try make()
    let blank = await model.sendPrompt("  \n ")
    XCTAssertEqual(blank, .notSent)
    let (empty, _, _, _) = try make(sessions: [])
    let nowhere = await empty.sendPrompt("hello")
    XCTAssertEqual(nowhere, .notSent)
    XCTAssertEqual(transport.connects, 0)
  }

  private func eventually(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("condition never held") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

/// Plays the relay: hands out one channel and lets the test answer its requests.
final class ScriptedTransport: AxoTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var made: ScriptedChannel?
  private var count = 0

  var connects: Int { lock.withLock { count } }

  func connect() async throws -> any AxoMessageChannel {
    lock.withLock {
      count += 1
      let channel = ScriptedChannel()
      made = channel
      return channel
    }
  }

  /// The `number`th connection (1 is the first), once it is made.
  func channel(number: Int) async throws -> ScriptedChannel {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if let channel = lock.withLock({ count >= number ? made : nil }) { return channel }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AxoClientError.connectionFailed("connection \(number) was never made")
  }

  func channel() async throws -> ScriptedChannel {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if let channel = lock.withLock({ made }) { return channel }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AxoClientError.connectionFailed("never connected")
  }
}

struct ScriptedRequest {
  let id: Int
  let method: String
  let params: [String: Any]
}

final class ScriptedChannel: AxoMessageChannel, @unchecked Sendable {
  let messages: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var sent: [Data] = []
  private var consumed = 0

  init() { (messages, continuation) = AsyncStream<Data>.makeStream() }

  /// Like the relay, agrees to a protocol version on its own; the connection does so on every new socket.
  func send(_ message: Data) async throws {
    let negotiation = lock.withLock { () -> Int? in
      if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
        object["method"] as? String == "axo.protocol.negotiate"
      {
        return object["id"] as? Int
      }
      sent.append(message)
      return nil
    }
    if let negotiation { reply(to: negotiation, result: #"{"protocolVersion":2,"methods":[]}"#) }
  }
  func close() { continuation.finish() }

  func push(_ raw: String) { continuation.yield(Data(raw.utf8)) }

  func reply(to id: Int, result: String) {
    push(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
  }

  func reply(to id: Int, error code: Int, message: String) {
    push(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#)
  }

  func nextRequest() async throws -> ScriptedRequest {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      let raw = lock.withLock { () -> Data? in
        guard consumed < sent.count else { return nil }
        defer { consumed += 1 }
        return sent[consumed]
      }
      if let raw {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return ScriptedRequest(
          id: try XCTUnwrap(object["id"] as? Int), method: try XCTUnwrap(object["method"] as? String),
          params: object["params"] as? [String: Any] ?? [:])
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AxoClientError.requestTimedOut
  }

  func answerNext(result: String) async throws {
    reply(to: try await nextRequest().id, result: result)
  }
}

private struct RefusingTransport: AxoTransport {
  func connect() async throws -> any AxoMessageChannel { throw RelayError.signInRequired }
}

struct NoHistory: PiHistoryLoading {
  func piEvents(of host: RemoteHostRef, session: SessionID, before cursor: Int64, limit: Int) async throws -> PiEventPage {
    PiEventPage(events: [], next: nil)
  }
}

struct FailingHistory: PiHistoryLoading {
  let error: Error
  func piEvents(of host: RemoteHostRef, session: SessionID, before cursor: Int64, limit: Int) async throws -> PiEventPage {
    throw error
  }
}

final class Pages: PiHistoryLoading, @unchecked Sendable {
  private let lock = NSLock()
  private var pages: [PiEventPage]
  private(set) var cursors: [Int64] = []
  init(_ pages: [PiEventPage]) { self.pages = pages }
  func piEvents(of host: RemoteHostRef, session: SessionID, before cursor: Int64, limit: Int) async throws -> PiEventPage {
    lock.withLock {
      cursors.append(cursor)
      return pages.isEmpty ? PiEventPage(events: [], next: nil) : pages.removeFirst()
    }
  }
}

final class FlakyOlder: PiHistoryLoading, @unchecked Sendable {
  let first: PiEventPage
  init(first: PiEventPage) { self.first = first }
  func piEvents(of host: RemoteHostRef, session: SessionID, before cursor: Int64, limit: Int) async throws -> PiEventPage {
    if cursor == 0 { return first }
    throw RelayError.httpStatus(503)
  }
}
