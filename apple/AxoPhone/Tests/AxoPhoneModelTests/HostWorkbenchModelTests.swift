import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

@MainActor
final class HostWorkbenchModelTests: XCTestCase {
  private func make(sessions: [(Int, String, [Int])] = [(1, "One", [10])]) throws
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
    let account = AccountSession(store: MemoryTokenStore(AccessToken("a.b.c")))
    let model = HostWorkbenchModel(
      host: remote, connection: HostConnection(transport: transport, host: remote.reference),
      account: account)
    return (model, transport, remote, account)
  }

  private func output(_ host: RemoteHost, session: Int = 1, shell: Int = 10, sequence: UInt64, _ text: String)
    -> RemoteHostEvent
  {
    .terminalOutput(
      host: host.reference, sessionID: SessionID(rawValue: Int64(session)),
      shellID: ShellID(rawValue: Int64(shell)), sequence: sequence, data: Data(text.utf8))
  }

  func testStartsWithTheHostsSessionsAndSelectsTheFirst() throws {
    let (model, _, _, _) = try make(sessions: [(2, "Two", [20]), (1, "One", [10])])
    XCTAssertEqual(model.sessions.map(\.sessionId), [1, 2])
    XCTAssertEqual(model.selectedSessionID, 1)
    XCTAssertEqual(model.focusedShell, 10)
  }

  func testOutputAccumulatesPerTerminalAndARepeatedFrameIsAppendedOnce() throws {
    let (model, _, host, _) = try make()
    model.apply(output(host, sequence: 0, "hel"))
    model.apply(output(host, sequence: 1, "lo\r\n"))
    model.apply(output(host, sequence: 1, "lo\r\n"))
    model.apply(output(host, shell: 99, sequence: 0, "other"))
    XCTAssertEqual(model.transcripts[10]?.text, "hello\n")
    XCTAssertEqual(model.transcripts[99]?.text, "other")
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
    model.apply(output(host, session: 1, shell: 10, sequence: 0, "x"))
    model.apply(.sessionRemoved(host: host.reference, sessionID: 1))
    XCTAssertEqual(model.sessions.map(\.sessionId), [2])
    XCTAssertEqual(model.selectedSessionID, 2, "the selection moves off a removed Session")
    XCTAssertNil(model.transcripts[10], "a removed Session's terminals are forgotten")
  }

  func testPresenceUpdatesTheStatusAndAnotherHostsEventsAreIgnored() throws {
    let (model, _, host, _) = try make()
    model.apply(.presence(host: host.reference, status: .offline))
    XCTAssertEqual(model.status, .offline)
    let stranger = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())
    model.apply(.presence(host: stranger, status: .online))
    model.apply(
      .terminalOutput(
        host: stranger, sessionID: 1, shellID: 10, sequence: 0, data: Data("evil".utf8)))
    XCTAssertEqual(model.status, .offline)
    XCTAssertNil(model.transcripts[10])
  }

  func testStartNegotiatesAndSubscribesThenAppliesPushedEvents() async throws {
    let (model, transport, host, _) = try make()
    let started = Task { await model.start() }
    let channel = try await transport.channel()
    try await channel.answerNext(result: #"{"protocolVersion":1,"methods":[]}"#)
    try await channel.answerNext(result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
    await started.value
    XCTAssertNil(model.failure)
    channel.push(
      #"{"jsonrpc":"2.0","method":"axo.host.event","params":{"subscriptionId":"\#(UUID().uuidString)","event":{"type":"host.data","hostId":"\#(host.hostId.uuidString)","hostGeneration":"\#(host.hostGeneration.uuidString)","event":{"type":"terminal.output","sessionId":1,"shellId":10,"sequence":0,"data":"aGkK"}}}}"#
    )
    try await eventually { model.transcripts[10]?.text == "hi\n" }
    model.stop()
  }

  func testTypingGoesToTheFocusedTerminalWithRisingSequenceNumbers() async throws {
    let (model, transport, _, _) = try make()
    let first = Task { await model.send("ls\n") }
    let channel = try await transport.channel()
    var sent = try await channel.nextRequest()
    XCTAssertEqual(sent.method, "axo.remote.terminal.input")
    XCTAssertEqual(sent.params["sequence"] as? Int, 0)
    XCTAssertEqual(sent.params["shellId"] as? Int, 10)
    XCTAssertEqual(sent.params["data"] as? String, "bHMK")
    channel.reply(to: sent.id, result: #"{"accepted":true,"sequence":0}"#)
    await first.value

    let second = Task { await model.send("x") }
    sent = try await channel.nextRequest()
    XCTAssertEqual(sent.params["sequence"] as? Int, 1)
    channel.reply(to: sent.id, result: #"{"accepted":true,"sequence":1}"#)
    await second.value
    XCTAssertNil(model.failure)
  }

  func testAStaleHostIsReportedButIsNotAnAccessProblem() async throws {
    let (model, transport, _, account) = try make()
    let typing = Task { await model.send("x") }
    let channel = try await transport.channel()
    let sent = try await channel.nextRequest()
    channel.reply(to: sent.id, error: -32002, message: "Stale host")
    await typing.value
    XCTAssertEqual(model.failure, "axod rejected the request (-32002): Stale host")
    XCTAssertEqual(account.state, .signedIn, "a stale host is not an Access problem")
  }

  func testARefusedConnectionSignsThePhoneOut() async throws {
    let id = UUID()
    let remote = try host("Studio", .online, sessions: [sessionJSON(host: id, id: 1, name: "One", shells: [10])])
    let account = AccountSession(store: MemoryTokenStore(AccessToken("a.b.c")))
    let model = HostWorkbenchModel(
      host: remote,
      connection: HostConnection(transport: RefusingTransport(), host: remote.reference),
      account: account)
    await model.send("x")
    XCTAssertEqual(account.state, .signedOut)
    XCTAssertEqual(model.failure, "Sign in with Cloudflare Access to continue.")
  }

  func testNothingIsSentWithoutATerminalOrText() async throws {
    let (model, transport, _, _) = try make(sessions: [(1, "Empty", [])])
    await model.send("x")
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

  func send(_ message: Data) async throws { lock.withLock { sent.append(message) } }
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
