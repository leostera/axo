import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// Stopping, answering, and sending when the connection fails.
@MainActor
final class HostWorkbenchLiveTests: XCTestCase {
  /// Says the chat is working (or not), as the host's listing would.
  private func listed(_ status: RemoteSessionStatus, in world: HostWorld) {
    world.model.update([RemoteSession(ClientSession(
      hostId: world.host.hostId, sessionId: 1, metadata: SessionMetadata(name: "One", createdAt: 1), status: status))])
  }

  // MARK: - Delivery

  func testAMessageWhoseConnectionDroppedIsKeptAsUncertainNotPutBack() async throws {
    let world = HostWorld()
    let model = world.model
    model.retryDelay = .seconds(60)
    _ = try await world.open(1, answering: Wire.opened([]))
    let sending = Task { await model.sendPrompt("deploy it") }
    let channel = try await world.channel()
    let request = try await channel.nextRequest()
    channel.close()
    let outcome = await sending.value
    XCTAssertEqual(outcome, .uncertain)
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.uncertain])
    XCTAssertEqual(model.failure, "Studio has not said whether it got your message; trying again.")

    // Its receipt, when it did arrive, retires it like any other.
    let commandId = try XCTUnwrap(request.params["commandId"] as? String)
    model.receive(records: [receipt(1, commandId), said(2, "deploy it")], epoch: 1, cursor: 2, in: 1)
    XCTAssertNil(model.pendingPrompts[1])
  }

  func testAnUncertainMessageIsSentAgainWithTheSameCommandAndAnOfflineAnswerKeepsIt() async throws {
    let world = HostWorld()
    let model = world.model
    model.retryDelay = .milliseconds(1)
    _ = try await world.open(1, answering: Wire.opened([]))
    let sending = Task { await model.sendPrompt("yes") }
    let first = try await world.channel()
    let sent = try await first.nextRequest()
    first.reply(to: sent.id, error: -32004, message: "Outcome unknown; reconcile commandId")
    let outcome = await sending.value
    XCTAssertEqual(outcome, .uncertain)
    // The retry finds the Mac offline: the first try may still land, so it stays pending.
    let again = try await first.nextRequest()
    XCTAssertEqual(again.params["commandId"] as? String, sent.params["commandId"] as? String)
    first.reply(to: again.id, error: -32005, message: "Host offline")
    let third = try await first.nextRequest()
    XCTAssertEqual(third.params["commandId"] as? String, sent.params["commandId"] as? String)
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.uncertain])
    first.reply(to: third.id, result: #"{"accepted":true}"#)
    for _ in 0..<100 where model.pendingPrompts[1]?.first?.state != .sent { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.sent])
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
    let world = HostWorld()
    let model = world.model
    model.retryDelay = .seconds(60)
    let sending = Task { await model.sendPrompt("x") }
    let channel = try await world.channel()
    _ = try await channel.nextRequest()
    channel.close()
    _ = await sending.value
    let pending = try XCTUnwrap(model.pendingPrompts[1]?.first)
    model.dismissPending(pending.id, in: 1)
    XCTAssertNil(model.pendingPrompts[1])
  }

  // MARK: - Stopping and answering

  func testStoppingAReplyNamesItsTurnOnceAndEndsWhenPiIsIdle() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([said(1, "go"), said(2, "on it", role: "assistant")]))
    await model.stopReply(in: 1)
    let channel = try await world.channel()
    XCTAssertFalse(channel.hasRequest, "nothing to stop while the agent is idle")

    listed(.working, in: world)
    let stopping = Task { await model.stopReply(in: 1) }
    let request = try await channel.nextRequest()
    XCTAssertEqual(request.method, "axo.remote.session.stop")
    XCTAssertEqual(request.params["turnId"] as? String, "e1", "the newest user message names the turn")
    XCTAssertEqual(request.params["sessionId"] as? String, SessionID.fixture(1).rawValue)
    XCTAssertTrue(model.stopping.contains(1))
    channel.reply(to: request.id, result: #"{"stopped":true}"#)
    await stopping.value
    await model.stopReply(in: 1)  // a second tap while stopping sends nothing more
    XCTAssertTrue(model.stopping.contains(1))

    listed(.ready, in: world)
    XCTAssertFalse(model.stopping.contains(1))
  }

  func testAStopTheMacRefusesIsNotLeftStopping() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([said(1, "go")]))
    listed(.working, in: world)
    let stopping = Task { await model.stopReply(in: 1) }
    let channel = try await world.channel()
    channel.reply(to: try await channel.nextRequest().id, error: -32004, message: "Resource not found")
    await stopping.value
    XCTAssertFalse(model.stopping.contains(1))
    XCTAssertNotNil(model.failure)
  }

  func testAnswersAreEnterEscapeOrTypedWords() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([]))
    await model.answer(.yes, in: 1)
    let idle = try await world.channel()
    XCTAssertFalse(idle.hasRequest, "no question, nothing to answer")

    model.receive(progress: "question", snapshot: jsonValue(#"{"kind":"confirm"}"#), in: 1)
    for (answer, method, key, text) in [
      (HostWorkbenchModel.Answer.yes, "axo.remote.session.key", "enter", nil),
      (.no, "axo.remote.session.key", "escape", nil),
      (.text("main"), "axo.remote.session.prompt", nil, "main"),
    ] as [(HostWorkbenchModel.Answer, String, String?, String?)] {
      let answering = Task { await model.answer(answer, in: 1) }
      let channel = try await world.channel()
      let request = try await channel.nextRequest()
      XCTAssertEqual(request.method, method)
      XCTAssertEqual(request.params["key"] as? String, key)
      XCTAssertEqual(request.params["text"] as? String, text)
      channel.reply(to: request.id, result: #"{"accepted":true}"#)
      await answering.value
    }
  }
}
