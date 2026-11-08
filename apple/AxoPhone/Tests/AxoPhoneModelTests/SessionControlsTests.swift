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

  // MARK: - Where a queued prompt waits

  /// What a run that took a message while streaming leaves in the log: the message is queued
  /// while reply 2 is written, and the run goes on to reply 3 before Pi takes it.
  private func run(_ commandId: String, delivery: String) -> [ClientRecord] {
    [
      said(1, "go"), said(2, "step one", role: "assistant"),
      queued(3, commandId, "and the docs", delivery: delivery),
      said(4, "step two", role: "assistant"), said(5, "step three", role: "assistant"),
    ]
  }

  private func texts(_ rows: [ConversationRow]) -> [String] {
    rows.map { row in
      switch row {
      case .message(let shown): shown.message.text
      case .pending(let prompt): "pending: \(prompt.text)"
      case .queued(let prompt): "queued: \(prompt.text)"
      }
    }
  }

  private func rows(_ transcript: ChatTranscript, pending: [HostWorkbenchModel.PendingPrompt] = []) -> [ConversationRow] {
    ConversationRow.rows(shown: shown(transcript), pending: pending, queued: transcript.queued)
  }

  func testAMessageSentWhileARunStreamsStaysAfterTheReplyItWasSentUnder() {
    for delivery in ["followUp", "steer"] {
      let records = run("c-1", delivery: delivery)
      var transcript = ChatTranscript(records: Array(records.prefix(3)))
      transcript.progress(slot: "message", snapshot: jsonValue(#"{"message":{"role":"assistant","timestamp":9,"content":"step tw"}}"#))
      XCTAssertEqual(texts(rows(transcript)), ["go", "step one", "step tw", "queued: and the docs"], "\(delivery): last until its reply is recorded")
      transcript.append(Array(records.dropFirst(3)))
      XCTAssertEqual(
        texts(rows(transcript)), ["go", "step one", "step two", "queued: and the docs", "step three"],
        "\(delivery): the run's later replies come below it")

      // Pi takes it: its user message shows at its place in the log, before its replies, once.
      transcript.append([receipt(6, "c-1"), said(7, "and the docs"), said(8, "docs done", role: "assistant")])
      XCTAssertEqual(texts(rows(transcript)), ["go", "step one", "step two", "step three", "and the docs", "docs done"])
    }
  }

  func testAfterARelaunchMidRunTheQueuedRowIsInTheSamePlaceOnce() {
    let records = run("c-1", delivery: "followUp")
    var live = ChatTranscript(records: Array(records.prefix(3)))
    live.append(Array(records.dropFirst(3)))
    let relaunched = ChatTranscript(records: records)
    XCTAssertEqual(texts(rows(relaunched)), ["go", "step one", "step two", "queued: and the docs", "step three"])
    XCTAssertEqual(rows(relaunched).map(\.id), rows(live).map(\.id))
    XCTAssertEqual(rows(relaunched).filter { $0.id == "prompt:c-1" }.count, 1)
  }

  func testRecordsThatComeTwiceLeaveOneCopy() {
    let records = run("c-1", delivery: "followUp")
    var transcript = ChatTranscript(records: records)
    transcript.append(records)
    transcript.append([queued(6, "c-1", "and the docs", delivery: "followUp")])
    XCTAssertEqual(texts(rows(transcript)), ["go", "step one", "step two", "queued: and the docs", "step three"])
  }

  func testAnOlderPageWhoseQueuedPromptHasNoReplyOnItGoesAfterTheFirstReplyHeld() {
    let records = run("c-1", delivery: "followUp")
    let older = ChatTranscript(records: Array(records.prefix(3)))
    var newer = ChatTranscript(records: Array(records.dropFirst(3)))
    XCTAssertEqual(texts(rows(newer)), ["step two", "step three"])
    newer.prepend(older: older)
    XCTAssertEqual(texts(rows(newer)), ["go", "step one", "step two", "queued: and the docs", "step three"])

    // And one whose reply is on the page moves down with what is held.
    let page = ChatTranscript(records: Array(records.prefix(4)))
    var rest = ChatTranscript(records: [records[4]])
    rest.prepend(older: page)
    XCTAssertEqual(texts(rows(rest)), ["go", "step one", "step two", "queued: and the docs", "step three"])
  }

  func testAReceiptThatRanACommandLeavesNothingWaiting() {
    var transcript = ChatTranscript(records: [said(1, "go"), queued(2, "c-9", "/axo-share", delivery: "followUp")])
    transcript.append([receipt(3, "c-9"), said(4, "Shared at https://axo.example/s/1", role: "assistant")])
    XCTAssertTrue(transcript.delivered.contains("c-9"), "a command writes no user message")
    XCTAssertEqual(transcript.queued, [])
    // Another receipt right after one is as good: the first ran as a command.
    transcript.append([receipt(5, "c-10"), receipt(6, "c-11"), said(7, "next")])
    XCTAssertTrue(transcript.delivered.isSuperset(of: ["c-10", "c-11"]))
  }

  func testThePhonesOwnMessageTakesItsQueuedEntrysPlaceAndACommandRetiresIt() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([said(1, "go")]))
    world.model.update([RemoteSession(ClientSession(
      hostId: world.host.hostId, sessionId: 1, metadata: SessionMetadata(name: "One", createdAt: 1), status: .working))])
    for text in ["and the docs", "/axo-share"] {
      let sending = Task { await model.sendPrompt(text) }
      let channel = try await world.channel()
      let request = try await channel.nextRequest("axo.remote.session.prompt")
      let commandId = try XCTUnwrap(request.params["commandId"] as? String)
      let next = (model.chats[1]?.lastCursor ?? 0) + 1
      model.receive(records: [queued(next, commandId, text, delivery: "followUp")], epoch: 1, cursor: next, in: 1)
      channel.reply(to: request.id, result: #"{"accepted":true}"#)
      _ = await sending.value
      XCTAssertNil(model.pendingPrompts[1], "the log's row from here on, under the same key")
      if text == "/axo-share" {
        model.receive(
          records: [receipt(next + 1, commandId), said(next + 2, "Shared", role: "assistant")], epoch: 1, cursor: next + 2, in: 1)
        XCTAssertFalse(model.chats[1]?.queued.contains { $0.commandId == commandId } ?? true, "ran as a command")
      }
    }
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

  func testSendInterruptsByDefaultAndAMacBefore037GetsTheSameMessageAsAFollowUp() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([said(1, "go")]))
    let sending = Task { await model.sendPrompt("stop and look at main") }
    let channel = try await world.channel()
    let first = try await channel.nextRequest("axo.remote.session.prompt")
    XCTAssertEqual(first.params["delivery"] as? String, "interrupt", "a tap interrupts")
    channel.reply(to: first.id, error: -32602, message: "Invalid params")
    let again = try await channel.nextRequest("axo.remote.session.prompt")
    XCTAssertEqual(again.params["commandId"] as? String, first.params["commandId"] as? String, "the same message")
    XCTAssertNil(again.params["delivery"], "as a follow-up, which every Mac knows")
    channel.reply(to: again.id, result: #"{"accepted":true}"#)
    let outcome = await sending.value
    XCTAssertEqual(outcome, .accepted)
    XCTAssertEqual(model.pendingPrompts[1]?.first?.delivery, .followUp, "shown as what the Mac took")
  }

  func testOnlyAnInterruptIsSentAgainAsAFollowUp() async throws {
    let world = HostWorld()
    let model = world.model
    _ = try await world.open(1, answering: Wire.opened([]))
    let sending = Task { await model.sendPrompt("look", delivery: .steer) }
    let channel = try await world.channel()
    let request = try await channel.nextRequest("axo.remote.session.prompt")
    XCTAssertEqual(request.params["delivery"] as? String, "steer")
    channel.reply(to: request.id, error: -32602, message: "Invalid params")
    let outcome = await sending.value
    XCTAssertEqual(outcome, .notSent)
    XCTAssertFalse(channel.hasRequest, "a steer refused is not changed into something else")
  }

  func testTheLogSaysWhichPromptsInterrupt() {
    let transcript = ChatTranscript(records: [said(1, "go"), queued(2, "c-1", "now this", delivery: "interrupt"), queued(3, "c-2", "x", delivery: "later")])
    XCTAssertEqual(transcript.queued.map(\.delivery), [.interrupt, .followUp], "one this app doesn't know waits as a follow-up")
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
