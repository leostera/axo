import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// What the phone sees of and changes in a chat's Pi (RFD0033): prompts it took while busy, as
/// the log holds them; follow-up or steer; a Pi still starting; Restart; the model and thinking
/// level; and its slash commands.
@MainActor
final class SessionControlsTests: XCTestCase {
  // MARK: - Queued in the log

  func testAPromptTheLogHoldsAsQueuedShowsUntilItsUserMessageTakesItsPlace() {
    var transcript = ChatTranscript(records: [
      said(1, "go"), said(2, "working on it", role: "assistant"),
      queued(3, "c-1", "and the docs", delivery: "followUp", files: ["notes.md"]),
      queued(4, "c-2", "look at main instead", delivery: "steer"),
    ])
    XCTAssertEqual(transcript.queued.map(\.commandId), ["c-1", "c-2"], "in the order Pi took them")
    XCTAssertEqual(transcript.queued.map(\.delivery), [.followUp, .steer])
    XCTAssertEqual(transcript.queued.first?.attachments, ["notes.md"])
    XCTAssertEqual(transcript.queued.first?.key, "prompt:c-1")

    // A receipt alone is not yet the message: the row stays until the message is there.
    transcript.append([receipt(5, "c-2")])
    XCTAssertEqual(transcript.queued.map(\.commandId), ["c-1", "c-2"])
    transcript.append([said(6, "look at main instead")])
    XCTAssertEqual(transcript.queued.map(\.commandId), ["c-1"])
    XCTAssertEqual(transcript.messages.last?.key, "prompt:c-2", "the message has the queued row's key")
  }

  func testQueuedPromptsShowFromTheLogAloneAfterARelaunch() {
    // A fresh phone, with nothing pending of its own: the records are all it has.
    let records = [said(1, "go"), queued(2, "c-1", "then this", delivery: "steer")]
    let transcript = ChatTranscript(records: records)
    let rows = ConversationRow.rows(shown: shown(transcript), pending: [], queued: transcript.queued)
    XCTAssertEqual(rows.map(\.id).last, "prompt:c-1")
  }

  func testAnOlderPageQueuedSinceDeliveredIsNotShownAsQueued() {
    let older = ChatTranscript(records: [said(1, "go"), queued(2, "c-1", "then this", delivery: "followUp")])
    var newer = ChatTranscript(records: [receipt(3, "c-1"), said(4, "then this")])
    newer.prepend(older: older)
    XCTAssertEqual(newer.queued, [])
  }

  func testQueuedRowsWaitBehindTheReplyAndHideTheirPendingRow() throws {
    var transcript = ChatTranscript(records: [said(1, "go"), queued(2, "c-1", "and then", delivery: "followUp")])
    transcript.progress(slot: "message", snapshot: jsonValue(#"{"message":{"role":"assistant","timestamp":5,"content":"On it"}}"#))
    let pending = HostWorkbenchModel.PendingPrompt(
      id: try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-00000000000c")), text: "later", state: .queued,
      behindReply: true)
    let mine = HostWorkbenchModel.PendingPrompt(id: UUID(), text: "mine", state: .sending, behindReply: true)
    let queuedTwice = QueuedPrompt(commandId: pending.id.uuidString.lowercased(), delivery: .followUp, text: "later", attachments: [])
    let rows = ConversationRow.rows(shown: shown(transcript), pending: [pending, mine], queued: transcript.queued + [queuedTwice])
    XCTAssertEqual(rows.map(\.id), ["e1", "reply:5#0", "prompt:c-1", pending.key, mine.key])
    guard case .queued = rows[3] else { return XCTFail("the log's row, not the pending one: \(rows[3])") }
  }

  // MARK: - Follow-up or steer

  func testASteerSaysSoAndAFollowUpSaysNothingAndTheQueuedRecordRetiresItsPendingRow() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([said(1, "go")]))
    for delivery in [PromptDelivery.followUp, .steer] {
      let sending = Task { await model.sendPrompt("now this", delivery: delivery) }
      let channel = try await world.channel()
      let request = try await channel.nextRequest("axo.remote.session.prompt")
      XCTAssertEqual(request.params["delivery"] as? String, delivery == .steer ? "steer" : nil)
      channel.reply(to: request.id, result: #"{"accepted":true}"#)
      let outcome = await sending.value
      XCTAssertEqual(outcome, .accepted)
      let commandId = try XCTUnwrap(request.params["commandId"] as? String)
      XCTAssertEqual(model.pendingPrompts[1]?.last?.delivery, delivery)
      let next = (model.chats[1]?.lastCursor ?? 0) + 1
      model.receive(
        records: [queued(next, commandId, "now this", delivery: delivery.rawValue)], epoch: 1, cursor: next, in: 1)
      XCTAssertNil(model.pendingPrompts[1], "the log shows it from here on")
      XCTAssertEqual(model.chats[1]?.queued.last?.commandId, commandId)
    }
  }

  func testAPromptAPiStillStartingRefusesWaitsAndIsSentAgainWithTheSameCommand() async throws {
    let world = HostWorld()
    let model = world.model
    model.retryDelay = .milliseconds(1)
    _ = try await world.open(1, answering: Wire.opened([]))
    let sending = Task { await model.sendPrompt("hello") }
    let channel = try await world.channel()
    let first = try await channel.nextRequest("axo.remote.session.prompt")
    channel.reply(to: first.id, error: -32008, message: "Pi is still starting")
    let outcome = await sending.value
    XCTAssertEqual(outcome, .uncertain, "kept, not put back in the box")
    XCTAssertEqual(model.pendingPrompts[1]?.map(\.state), [.waitingForPi])
    let again = try await channel.nextRequest("axo.remote.session.prompt")
    XCTAssertEqual(again.params["commandId"] as? String, first.params["commandId"] as? String)
    channel.reply(to: again.id, result: #"{"accepted":true}"#)
    try await eventually { model.pendingPrompts[1]?.first?.state == .sent }
  }

  // MARK: - Restart

  func testRestartShowsRestartingUntilTheChatIsReadyAgain() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([said(1, "go")]))
    let restarting = Task { await model.restartPi(in: 1) }
    let channel = try await world.channel()
    let request = try await channel.nextRequest("axo.remote.session.restart")
    XCTAssertEqual(request.params["sessionId"] as? String, SessionID.fixture(1).rawValue)
    XCTAssertEqual(model.chat(1).restart, .asked)
    channel.reply(to: request.id, result: #"{"restarted":true}"#)
    await restarting.value

    listed(.ready, in: world)
    XCTAssertEqual(model.chat(1).restart, .asked, "still ready from before the restart")
    listed(.unavailable, in: world)
    XCTAssertEqual(model.chat(1).restart, .underway)
    listed(.starting, in: world)
    XCTAssertEqual(model.chat(1).restart, .underway)
    listed(.ready, in: world)
    XCTAssertNil(model.chat(1).restart)
  }

  func testARestartThatNeverShowsIsDoneAfterAWhileAndARefusedOneAtOnce() async throws {
    let world = HostWorld()
    let model = world.model
    model.restartGrace = .milliseconds(10)
    let restarting = Task { await model.restartPi(in: 1) }
    let channel = try await world.channel()
    channel.reply(to: try await channel.nextRequest("axo.remote.session.restart").id, result: #"{"restarted":true}"#)
    await restarting.value
    try await eventually { model.chat(1).restart == nil }

    let refused = Task { await model.restartPi(in: 1) }
    channel.reply(to: try await channel.nextRequest("axo.remote.session.restart").id, error: -32004, message: "Resource not found")
    await refused.value
    XCTAssertNil(model.chat(1).restart)
    XCTAssertNotNil(model.failure)
  }

  // MARK: - Model and thinking level

  func testTheListingSaysWhatPiRunsAndAPickShowsAtOnceUntilTheListingSays() async throws {
    let world = HostWorld()
    let model = world.model
    let opus = PiModelRef(provider: "anthropic", id: "claude-opus-4-1", name: "Opus 4.1")
    listed(.ready, pi: PiRuntime(model: opus, thinkingLevel: .high), in: world)
    XCTAssertEqual(model.piRuntime(of: 1)?.label, "Opus 4.1 · High")

    let loading = Task { await model.loadModels(in: 1) }
    let channel = try await world.channel()
    let read = try await channel.nextRequest("axo.remote.session.models")
    channel.reply(
      to: read.id,
      result: #"{"models":[{"provider":"anthropic","id":"claude-opus-4-1","name":"Opus 4.1","thinkingLevels":["off","low","high","xhigh"]},{"provider":"openai","id":"gpt-5","name":"GPT-5","thinkingLevels":["off","minimal","future"]}]}"#)
    let loaded = await loading.value
    let models = try XCTUnwrap(loaded)
    XCTAssertEqual(models.map(\.name), ["Opus 4.1", "GPT-5"])
    XCTAssertEqual(models[1].thinkingLevels, [.off, .minimal], "a level this app doesn't know isn't offered")

    // Another model: the level it lacks isn't shown until Pi says which it moved to.
    let switching = Task { await model.setModel(models[1], in: 1) }
    let set = try await channel.nextRequest("axo.remote.session.model.set")
    XCTAssertEqual(set.params["model"] as? [String: String], ["provider": "openai", "id": "gpt-5"])
    XCTAssertNil(set.params["thinkingLevel"])
    XCTAssertEqual(model.piRuntime(of: 1)?.label, "GPT-5")
    channel.reply(to: set.id, result: #"{"saved":true}"#)
    await switching.value
    XCTAssertEqual(model.piRuntime(of: 1)?.label, "GPT-5", "until the listing says")
    let gpt = PiModelRef(provider: "openai", id: "gpt-5", name: "GPT-5")
    listed(.ready, pi: PiRuntime(model: gpt, thinkingLevel: .minimal), in: world)
    XCTAssertEqual(model.piRuntime(of: 1)?.label, "GPT-5 · Minimal")

    // A level alone.
    let thinking = Task { await model.setModel(thinkingLevel: .off, in: 1) }
    let level = try await channel.nextRequest("axo.remote.session.model.set")
    XCTAssertNil(level.params["model"])
    XCTAssertEqual(level.params["thinkingLevel"] as? String, "off")
    XCTAssertEqual(model.piRuntime(of: 1)?.label, "GPT-5 · Off")
    channel.reply(to: level.id, result: #"{"saved":true}"#)
    await thinking.value
  }

  func testAModelPiHasNoCredentialsForGoesBackAndSaysWhy() async throws {
    let world = HostWorld()
    let model = world.model
    let opus = PiModelRef(provider: "anthropic", id: "claude-opus-4-1", name: "Opus 4.1")
    listed(.ready, pi: PiRuntime(model: opus, thinkingLevel: .high), in: world)
    let other = PiModel(provider: "openai", id: "gpt-5", name: "GPT-5", thinkingLevels: [.high])
    let switching = Task { await model.setModel(other, in: 1) }
    let channel = try await world.channel()
    let set = try await channel.nextRequest("axo.remote.session.model.set")
    XCTAssertEqual(model.piRuntime(of: 1)?.label, "GPT-5 · High", "the level the new model has stays")
    channel.reply(to: set.id, error: -32007, message: "No credentials for openai")
    await switching.value
    XCTAssertEqual(model.piRuntime(of: 1)?.label, "Opus 4.1 · High")
    XCTAssertEqual(model.failure, "Pi isn't signed in to that model's provider on the Mac.")
  }

  // MARK: - Slash commands

  func testCommandsAreReadFromThePiAndKeptWhenARereadFails() async throws {
    let world = HostWorld()
    let model = world.model
    let loading = Task { await model.loadCommands(in: 1) }
    let channel = try await world.channel()
    channel.reply(
      to: try await channel.nextRequest("axo.remote.session.commands").id,
      result: #"{"commands":[{"name":"review","description":"Review the change","source":"prompt"},{"name":"axo-share","description":"Share this conversation","source":"extension"},{"name":"new","description":"","source":"later"}]}"#)
    let loaded = await loading.value
    let commands = try XCTUnwrap(loaded)
    XCTAssertEqual(commands.map(\.name), ["review", "axo-share", "new"])
    XCTAssertEqual(commands.map(\.source), [.prompt, .extension, nil])

    let again = Task { await model.loadCommands(in: 1) }
    channel.reply(to: try await channel.nextRequest("axo.remote.session.commands").id, error: -32004, message: "nope")
    let kept = await again.value
    XCTAssertEqual(kept?.map(\.name), ["review", "axo-share", "new"])
  }

  func testSlashCommandsNarrowAsTyped() {
    let commands = [
      PiCommand(name: "review", description: "Review the change", source: .prompt),
      PiCommand(name: "axo-share", description: "Share this conversation", source: .extension),
      PiCommand(name: "hivemind", description: "Search the team's memory", source: .skill),
    ]
    XCTAssertNil(SlashCommands.query(in: "review this"), "only at the start of the box")
    XCTAssertNil(SlashCommands.query(in: "/review "), "once arguments start, the list goes")
    XCTAssertEqual(SlashCommands.query(in: "/"), "")
    XCTAssertEqual(SlashCommands.matching(commands, query: "").map(\.name), ["axo-share", "hivemind", "review"])
    XCTAssertEqual(SlashCommands.matching(commands, query: "sha").map(\.name), ["axo-share"], "anywhere in the name")
    XCTAssertEqual(SlashCommands.matching(commands, query: "R").map(\.name), ["review", "axo-share"], "names starting with it first")
    XCTAssertEqual(SlashCommands.inserting(commands[0]), "/review ")
  }

  // MARK: - Protocol

  func testTheListingCarriesPiAndAnUnknownLevelHidesOnlyTheLevel() throws {
    let json = #"{"hostId":"18355f00-95fd-4c93-8586-a71a8a52bf73","sessionId":"\#(SessionID.fixture(1).rawValue)","epoch":1,"head":0,"status":"ready","metadata":{"name":"One","emoji":null,"workspaceId":null,"workspaceName":null,"hasAgent":true,"createdAt":null,"lastMessageAt":null,"archived":false,"pi":{"model":{"provider":"anthropic","id":"claude-opus-4-1","name":"Opus 4.1"},"thinkingLevel":"ultra"}}}"#
    let session = RemoteSession(try JSONDecoder().decode(ClientSession.self, from: Data(json.utf8)))
    XCTAssertEqual(session.pi?.model?.name, "Opus 4.1")
    XCTAssertNil(session.pi?.thinkingLevel)
    XCTAssertEqual(session.pi?.label, "Opus 4.1")
    XCTAssertNil(PiRuntime(model: nil, thinkingLevel: .high).label, "no model, no label")
    XCTAssertEqual(ThinkingLevel.xhigh.title, "Extra High")
  }

  // MARK: - Helpers

  private func listed(_ status: RemoteSessionStatus, pi: PiRuntime? = nil, in world: HostWorld) {
    world.model.update([RemoteSession(ClientSession(
      hostId: world.host.hostId, sessionId: 1, metadata: SessionMetadata(name: "One", createdAt: 1, pi: pi), status: status))])
  }

  private func shown(_ transcript: ChatTranscript) -> [ConversationReveal.Shown] {
    transcript.messages.map { .init(message: $0, isLive: false, presentation: .plain) }
      + transcript.live.map { .init(message: $0, isLive: true, presentation: .plain) }
  }
}

/// A prompt the Session's Pi took while busy, as it writes it to the log (RFD0033).
func queued(_ cursor: Int64, _ commandId: String, _ text: String, delivery: String, files: [String] = []) -> ClientRecord {
  let attachments = files.map { #"{"path":"/tmp/\#($0)","asset":"sha256:00","name":"\#($0)","mimeType":"text/plain","size":1}"# }
  return ClientRecord(
    cursor: cursor, id: "e\(cursor)",
    line: #"{"type":"custom","id":"e\#(cursor)","customType":"axo.command.queued","data":{"commandId":"\#(commandId)","delivery":"\#(delivery)","text":"\#(text)","attachments":[\#(attachments.joined(separator: ","))]}}"#)
}
