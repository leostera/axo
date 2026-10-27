import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// Stopping, answering, sending when the connection fails, and staying connected.
@MainActor
final class HostWorkbenchLiveTests: XCTestCase {
  private func make() throws -> (HostWorkbenchModel, ScriptedTransport, RemoteHost, Pages) {
    let id = UUID()
    let remote = try JSONDecoder().decode(
      RemoteHost.self,
      from: Data(
        """
        {"hostId":"\(id.uuidString)","hostGeneration":"\(UUID().uuidString)","label":"Studio",
        "hostKind":"macos","status":"online","stale":false,"lastSeenAt":"2026-10-16T00:00:00Z",
        "sessions":[\(sessionJSON(host: id, id: 1, name: "One", shells: [10]))]}
        """.utf8))
    let transport = ScriptedTransport()
    let history = Pages([])
    let model = HostWorkbenchModel(
      host: remote, connection: HostConnection(transport: transport, host: remote.reference),
      history: history, account: AccountSession(store: MemoryTokenStore(SessionToken.fixture())),
      reconnectDelays: [.milliseconds(10)])
    model.selectedSessionID = 1
    return (model, transport, remote, history)
  }

  private func pi(_ name: String, _ json: String = "null", sequence: UInt64 = 1) -> PiEventRecord {
    PiEventRecord(
      streamId: UUID(), sequence: sequence, name: name,
      data: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
  }

  private func eventually(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("condition never held") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  // MARK: - Delivery

  func testAMessageWhoseConnectionDroppedIsKeptAsUncertainNotPutBack() async throws {
    let (model, transport, _, _) = try make()
    let sending = Task { await model.sendPrompt("deploy it") }
    let channel = try await transport.channel()
    _ = try await channel.nextRequest()
    channel.close()
    let outcome = await sending.value
    XCTAssertEqual(outcome, .uncertain)
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.uncertain])
    XCTAssertEqual(model.failure, "The connection to Studio dropped while sending. Check the chat before sending again.")

    // Pi's record of it, when it did arrive, retires it like any other.
    model.apply(.piEvent(host: model.reference, sessionID: 1, event: pi(
      "message.end", #"{"message":{"role":"user","content":"deploy it"}}"#)))
    XCTAssertNil(model.pendingPrompts[1])
  }

  func testTheRelaysUnknownOutcomeIsUncertainButAMissingPiIsNotSent() {
    XCTAssertTrue(HostWorkbenchModel.deliveryUncertain(
      AxoClientError.serverRejected(code: -32004, message: "Outcome unknown; reconcile commandId")))
    XCTAssertTrue(HostWorkbenchModel.deliveryUncertain(AxoClientError.requestTimedOut))
    XCTAssertFalse(HostWorkbenchModel.deliveryUncertain(
      AxoClientError.serverRejected(code: -32004, message: "Resource not found")))
    XCTAssertFalse(HostWorkbenchModel.deliveryUncertain(AxoClientError.connectionFailed("offline")))
  }

  func testAMessageThatCouldNotConnectWasNotSentAndSaysSo() {
    XCTAssertEqual(
      HostWorkbenchModel.notSentReason(AxoClientError.connectionFailed("offline"), host: "Studio"),
      "Not sent: no connection to Studio. Your message is still in the box.")
  }

  func testAnUncertainMessageCanBeDismissed() async throws {
    let (model, transport, _, _) = try make()
    let sending = Task { await model.sendPrompt("x") }
    let channel = try await transport.channel()
    _ = try await channel.nextRequest()
    channel.close()
    _ = await sending.value
    let pending = try XCTUnwrap(model.pendingPrompts[1]?.first)
    model.dismissPending(pending.id, in: 1)
    XCTAssertNil(model.pendingPrompts[1])
  }

  // MARK: - Stopping and answering

  func testStoppingAReplyPressesEscapeOnceAndEndsWhenPiIsIdle() async throws {
    let (model, transport, _, _) = try make()
    await model.stopReply(in: 1)
    XCTAssertEqual(transport.connects, 0, "nothing to stop while Pi is idle")

    model.apply(.piEvent(host: model.reference, sessionID: 1, event: pi("agent.start")))
    let stopping = Task { await model.stopReply(in: 1) }
    let channel = try await transport.channel()
    let request = try await channel.nextRequest()
    XCTAssertEqual(request.method, "axo.remote.session.key")
    XCTAssertEqual(request.params["key"] as? String, "escape")
    XCTAssertEqual(request.params["sessionId"] as? Int, 1)
    XCTAssertTrue(model.stopping.contains(1))
    channel.reply(to: request.id, result: #"{"accepted":true}"#)
    await stopping.value
    await model.stopReply(in: 1)  // a second tap while stopping sends nothing more
    XCTAssertTrue(model.stopping.contains(1))

    model.apply(.piEvent(host: model.reference, sessionID: 1, event: pi("agent.end", sequence: 2)))
    XCTAssertFalse(model.stopping.contains(1))
  }

  func testAStopTheMacRefusesIsNotLeftStopping() async throws {
    let (model, transport, _, _) = try make()
    model.apply(.piEvent(host: model.reference, sessionID: 1, event: pi("agent.start")))
    let stopping = Task { await model.stopReply(in: 1) }
    let channel = try await transport.channel()
    channel.reply(to: try await channel.nextRequest().id, error: -32004, message: "Resource not found")
    await stopping.value
    XCTAssertFalse(model.stopping.contains(1))
    XCTAssertNotNil(model.failure)
  }

  func testAnswersAreEnterEscapeOrTypedWords() async throws {
    let (model, transport, _, _) = try make()
    await model.answer(.yes, in: 1)
    XCTAssertEqual(transport.connects, 0, "no question, nothing to answer")

    model.apply(.piEvent(host: model.reference, sessionID: 1, event: pi("ui.prompt.start", #"{"kind":"confirm"}"#)))
    for (answer, method, key, text) in [
      (HostWorkbenchModel.Answer.yes, "axo.remote.session.key", "enter", nil),
      (.no, "axo.remote.session.key", "escape", nil),
      (.text("main"), "axo.remote.session.prompt", nil, "main"),
    ] as [(HostWorkbenchModel.Answer, String, String?, String?)] {
      let answering = Task { await model.answer(answer, in: 1) }
      let channel = try await transport.channel()
      let request = try await channel.nextRequest()
      XCTAssertEqual(request.method, method)
      XCTAssertEqual(request.params["key"] as? String, key)
      XCTAssertEqual(request.params["text"] as? String, text)
      channel.reply(to: request.id, result: #"{"accepted":true}"#)
      await answering.value
    }
  }

  // MARK: - Staying connected

  func testADroppedConnectionReconnectsSubscribesAgainAndCatchesUp() async throws {
    let (model, transport, host, history) = try make()
    let started = Task { await model.start() }
    let first = try await transport.channel(number: 1)
    try await first.answerNext(result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
    await started.value
    XCTAssertEqual(model.link, .connected)

    first.close()
    try await eventually { model.link == .reconnecting }
    let second = try await transport.channel(number: 2)
    let resubscribe = try await second.nextRequest()
    XCTAssertEqual(resubscribe.method, "axo.host.subscribe")
    second.reply(to: resubscribe.id, result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
    try await eventually { model.link == .connected }
    try await eventually { history.cursors == [0] }

    // Events flow again on the new connection.
    second.push(
      #"{"jsonrpc":"2.0","method":"axo.host.event","params":{"subscriptionId":"\#(UUID().uuidString)","event":{"type":"host.data","hostId":"\#(host.hostId.uuidString)","hostGeneration":"\#(host.hostGeneration.uuidString)","event":{"type":"pi.event","sessionId":1,"piSessionId":"pi-1","streamId":"\#(UUID().uuidString)","sequence":1,"name":"agent.start","data":null}}}}"#
    )
    try await eventually { model.chats[1]?.activity == .working }
    model.stop()
  }

  func testTheBackgroundLetsTheConnectionGoAndTheForegroundComesBack() async throws {
    let (model, transport, _, _) = try make()
    let started = Task { await model.start() }
    let first = try await transport.channel(number: 1)
    try await first.answerNext(result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
    await started.value

    model.suspend()
    XCTAssertEqual(model.link, .suspended)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(transport.connects, 1, "no reconnecting in the background")
    XCTAssertEqual(model.link, .suspended, "letting go on purpose is not a loss")

    model.resume()
    let second = try await transport.channel(number: 2)
    try await second.answerNext(result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
    try await eventually { model.link == .connected }
    model.stop()
  }
}
