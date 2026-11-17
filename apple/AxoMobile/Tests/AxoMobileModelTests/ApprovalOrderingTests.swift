import AxoClient
import AxoProtocol
import XCTest

@testable import AxoMobileModel

@MainActor
private final class ApprovalFixture {
  let world: PhoneWorld
  let mac: Mac
  let channel: ScriptedChannel
  let id = UUID().uuidString.lowercased()
  var phone: PhoneWorkbench { world.workbench }
  var destination: PhoneWorkbench.Selection { .init(host: mac.id, session: 1) }

  init() async throws {
    let mac = Mac("Approval Mac", online: true, sessions: [1, 2])
    let world = PhoneWorld([mac], answers: false)
    try await world.start()
    let channel = try await world.transport.channel()
    self.mac = mac
    self.world = world
    self.channel = channel
    phone.select(host: mac.id, session: 1)
    let opening = try await channel.nextRequest("axo.client.session.open")
    channel.reply(to: opening.id, result: Wire.opened(epoch: nil, []))
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    channel.notify("axo.elicitation.requested",
      #"{"hostId":"\#(mac.id.uuidString.lowercased())","elicitation":{"id":"\#(id)","sessionId":"\#((1 as SessionID).rawValue)","kind":"confirm","message":"Approve the current work?","createdAt":\#(now),"expiresAt":\#(now + 300_000)}}"#)
    try await eventually { self.phone.questions.count == 1 }
  }

  func resolved() {
    channel.notify("axo.elicitation.resolved",
      #"{"hostId":"\#(mac.id.uuidString.lowercased())","id":"\#(id)","sessionId":"\#((1 as SessionID).rawValue)","action":"accept"}"#)
  }
}

@MainActor
private final class RecordedWords: DictationEngine {
  var audioLevel: Double { 0 }
  var heard: ((HeardText) -> Void)?
  func requestPermission() async -> Bool { true }
  func prepare(progress: @escaping @MainActor (VoiceSetupProgress) -> Void) async throws {}
  func start(heard: @escaping @MainActor (HeardText) -> Void, interrupted: @escaping @MainActor () -> Void) async throws { self.heard = heard }
  func finish() async throws -> String { "These are the recorded words." }
  func cancel() async {}
}

@MainActor
final class ApprovalOrderingTests: XCTestCase {
  func testRecordingThenYesThenSendWaitsForTheAnswerAndNeverInterruptsIt() async throws {
    let f = try await ApprovalFixture()
    let engine = RecordedWords()
    let voice = VoicePrompt(engine: engine)
    voice.start(in: f.destination)
    try await eventually { voice.isListening }
    engine.heard?(HeardText(settled: "These are the recorded words."))
    let answering = Task { await f.phone.answer(f.id, .accept) }
    let answer = try await f.channel.nextRequest("axo.elicitation.resolve")
    voice.finish(.send)
    try await eventually { voice.transcript != nil }
    let transcript = try XCTUnwrap(voice.transcript)
    XCTAssertTrue(voice.consume(transcript))
    f.phone.setDraft(transcript.text, for: f.destination)
    let sending = Task { await f.phone.send() }
    try await eventually { f.phone.isSending }
    XCTAssertFalse(f.channel.hasRequest, "The answer RPC must retire before Send starts")
    f.resolved()
    f.channel.reply(to: answer.id, result: #"{"resolved":true}"#)
    await answering.value
    let prompt = try await f.channel.nextRequest("axo.remote.session.prompt")
    XCTAssertEqual(prompt.params["text"] as? String, transcript.text)
    XCTAssertNotEqual(prompt.params["delivery"] as? String, "interrupt")
    f.channel.reply(to: prompt.id, result: #"{"accepted":true}"#)
    let outcome = await sending.value
    XCTAssertEqual(outcome, .sent)
  }

  func testAnswerFailureKeepsTheMessageAsAnUnsentDraft() async throws {
    let f = try await ApprovalFixture()
    let answering = Task { await f.phone.answer(f.id, .accept) }
    let answer = try await f.channel.nextRequest("axo.elicitation.resolve")
    f.phone.setDraft("Keep my voice message", for: f.destination)
    let sending = Task { await f.phone.send() }
    try await eventually { f.phone.isSending }
    XCTAssertFalse(f.channel.hasRequest)
    f.channel.reply(to: answer.id, error: -32005, message: "Answer did not reach the Mac")
    await answering.value
    let outcome = await sending.value
    XCTAssertEqual(outcome, .failed)
    XCTAssertEqual(f.phone.draft(for: f.destination), "Keep my voice message")
    XCTAssertFalse(f.channel.hasRequest)
  }

  func testSwitchingChatsDuringAnswerCannotRedirectTheWaitingMessage() async throws {
    let f = try await ApprovalFixture()
    let answering = Task { await f.phone.answer(f.id, .accept) }
    let answer = try await f.channel.nextRequest("axo.elicitation.resolve")
    f.phone.setDraft("Words for the original chat", for: f.destination)
    let sending = Task { await f.phone.send() }
    try await eventually { f.phone.isSending }
    f.phone.select(host: f.mac.id, session: 2)
    let opening = try await f.channel.nextRequest("axo.client.session.open")
    f.channel.reply(to: opening.id, result: Wire.opened(epoch: nil, []))
    f.channel.reply(to: answer.id, result: #"{"resolved":true}"#)
    await answering.value
    let outcome = await sending.value
    XCTAssertEqual(outcome, .failed)
    XCTAssertEqual(f.phone.draft(for: f.destination), "Words for the original chat")
    XCTAssertFalse(f.channel.hasRequest)
  }
}
