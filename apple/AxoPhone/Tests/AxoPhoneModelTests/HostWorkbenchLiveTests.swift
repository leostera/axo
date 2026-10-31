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
    _ = try await world.open(1, answering: Wire.opened([]))
    let sending = Task { await model.sendPrompt("deploy it") }
    let channel = try await world.channel()
    _ = try await channel.nextRequest()
    channel.close()
    let outcome = await sending.value
    XCTAssertEqual(outcome, .uncertain)
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.uncertain])
    XCTAssertEqual(model.failure, "The connection to Studio dropped while sending. Check the chat before sending again.")

    // Pi's record of it, when it did arrive, retires it like any other.
    model.receive(records: [said(1, "deploy it")], epoch: 1, cursor: 1, in: 1)
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
    let world = HostWorld()
    let model = world.model
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

  func testStoppingAReplyPressesEscapeOnceAndEndsWhenPiIsIdle() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([]))
    await model.stopReply(in: 1)
    let channel = try await world.channel()
    XCTAssertFalse(channel.hasRequest, "nothing to stop while the agent is idle")

    listed(.working, in: world)
    let stopping = Task { await model.stopReply(in: 1) }
    let request = try await channel.nextRequest()
    XCTAssertEqual(request.method, "axo.remote.session.key")
    XCTAssertEqual(request.params["key"] as? String, "escape")
    XCTAssertEqual(request.params["sessionId"] as? String, SessionID.fixture(1).rawValue)
    XCTAssertTrue(model.stopping.contains(1))
    channel.reply(to: request.id, result: #"{"accepted":true}"#)
    await stopping.value
    await model.stopReply(in: 1)  // a second tap while stopping sends nothing more
    XCTAssertTrue(model.stopping.contains(1))

    listed(.ready, in: world)
    XCTAssertFalse(model.stopping.contains(1))
  }

  func testAStopTheMacRefusesIsNotLeftStopping() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([]))
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
