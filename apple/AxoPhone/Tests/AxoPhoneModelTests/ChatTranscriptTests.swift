import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// Records are Pi session file lines (`pi/3`); `entry` builds one around a message.
func piRecord(_ cursor: Int64, message json: String) -> ClientRecord {
  ClientRecord(cursor: cursor, id: "e\(cursor)", line: #"{"type":"message","id":"e\#(cursor)","message":\#(json)}"#)
}

func jsonValue(_ json: String) -> JSONValue {
  try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

final class ChatTranscriptTests: XCTestCase {
  private func message(_ cursor: Int64, role: String, content: String) -> ClientRecord {
    piRecord(cursor, message: #"{"role":"\#(role)","content":\#(content)}"#)
  }

  private func record(_ cursor: Int64, _ message: String) -> ClientRecord { piRecord(cursor, message: message) }

  private func transcript(_ records: ClientRecord...) -> ChatTranscript { ChatTranscript(records: records) }

  func testAnOlderPageGoesFirstAndItsToolIsAnsweredByAResultAlreadyShown() {
    // Pi's call is on the older page; its result arrived on the newer one.
    let call = record(2, #"{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}]}"#)
    let result = record(3, #"{"role":"toolResult","toolCallId":"c1","content":"README.md"}"#)
    var transcript = transcript(result, message(4, role: "user", content: #""thanks""#))
    transcript.prepend(older: ChatTranscript(records: [message(1, role: "user", content: #""list files""#), call]))
    XCTAssertEqual(transcript.messages.map(\.role), [.user, .tool, .user])
    XCTAssertEqual(transcript.messages[1].tool?.status, .completed)
    XCTAssertEqual(transcript.messages[1].tool?.output, "README.md")
    XCTAssertEqual(transcript.firstCursor, 1)
    XCTAssertEqual(transcript.lastCursor, 4)
  }

  func testAnOlderPageThatOverlapsWhatIsHeldIsNotPutFirst() {
    var transcript = transcript(message(2, role: "user", content: #""second""#))
    transcript.prepend(older: ChatTranscript(records: [message(1, role: "user", content: #""first""#), message(2, role: "user", content: #""second""#)]))
    XCTAssertEqual(transcript.messages.map(\.text), ["second"])
  }

  func testWholeMessagesBecomeTheConversationInOrder() {
    var transcript = ChatTranscript()
    transcript.append([message(1, role: "user", content: #""hello""#)])
    transcript.append([message(2, role: "assistant", content: #"[{"type":"text","text":"Hi there"}]"#)])
    XCTAssertEqual(transcript.messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(transcript.messages.map(\.text), ["hello", "Hi there"])
    XCTAssertEqual(transcript.messages.map(\.id), ["e1", "e2"], "a message is named by its entry")
  }

  func testEntriesThatAreNotMessagesAndOtherFormatsShowNothingButAreHeld() {
    var transcript = ChatTranscript()
    transcript.append([
      ClientRecord(cursor: 1, id: "s", line: #"{"type":"session","id":"s","version":3}"#),
      ClientRecord(cursor: 2, id: "m", line: #"{"type":"model_change","id":"m"}"#),
      ClientRecord(cursor: 3, id: "x", format: "atxf/1", line: #"{"type":"message","message":{"role":"user","content":"hi"}}"#),
      ClientRecord(cursor: 4, id: nil, line: "not json"),
    ])
    XCTAssertTrue(transcript.messages.isEmpty)
    XCTAssertEqual(transcript.lastCursor, 4)
  }

  func testTextBlocksJoinAndImagesAreNamedNotShown() {
    let transcript = transcript(message(1, role: "user", content: #"[{"type":"text","text":"look"},{"type":"image"},{"type":"text","text":"at this"}]"#))
    XCTAssertEqual(transcript.messages.first?.text, "look\n[Image attachment]\nat this")
  }

  func testAToolsPicturesAreItsResultsOwnAndTheImageAssetsItsOutputNames() throws {
    let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    let hex = String(repeating: "ab", count: 32)
    let output = #"[{"attachment":{"asset":"sha256:\#(hex)","mimeType":"image/png","name":"a.png"},"type":"image"},{"asset":"sha256:\#(hex)","mimeType":"image/png"},{"asset":"sha256:\#(String(repeating: "cd", count: 32))","mimeType":"application/pdf"}]"#
    let encoded = String(data: try JSONEncoder().encode(output), encoding: .utf8)!
    let transcript = transcript(
      record(1, #"{"role":"assistant","content":[{"type":"toolCall","id":"r","name":"read","arguments":{"path":"/tmp/a.png"}},{"type":"toolCall","id":"c","name":"codemode","arguments":{"code":"1"}}]}"#),
      record(2, #"{"role":"toolResult","toolCallId":"r","content":[{"type":"text","text":"Read image file"},{"type":"image","data":"\#(pixel)","mimeType":"image/png"}]}"#),
      record(3, #"{"role":"toolResult","toolCallId":"c","content":[{"type":"text","text":\#(encoded)}]}"#))
    let tools = transcript.messages.compactMap(\.tool)
    XCTAssertEqual(tools.first?.images, [ChatImage(id: 0, source: .data(Data(base64Encoded: pixel)!), mimeType: "image/png")])
    XCTAssertEqual(tools.last?.images, [ChatImage(id: 0, source: .asset(hex), mimeType: "image/png")], "each image asset once; not a PDF")
  }

  func testSystemMessagesAndBareToolResultsAreNotShown() {
    let transcript = transcript(message(1, role: "toolResult", content: #""output""#), message(2, role: "system", content: #""setup""#))
    XCTAssertTrue(transcript.messages.isEmpty)
  }

  func testAReplyKeepsPiOrderReasoningWordsThenTools() {
    let transcript = transcript(record(1, """
      {"role":"assistant","timestamp":1792810292069,"content":[
        {"type":"thinking","thinking":"Let me look"},
        {"type":"text","text":"Checking"},{"type":"text","text":"the repo"},
        {"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"git status","timeout":10}},
        {"type":"toolCall","id":"c2","name":"read","arguments":{"path":"README.md"}}]}
      """.replacingOccurrences(of: "\n", with: "")))
    XCTAssertEqual(transcript.messages.map(\.role), [.thinking, .assistant, .tool, .tool])
    XCTAssertEqual(transcript.messages[1].text, "Checking\nthe repo")
    XCTAssertEqual(transcript.messages.map(\.timestamp), Array(repeating: 1792810292069, count: 4))
    let shell = transcript.messages[2].tool
    XCTAssertEqual(shell?.kind, .shell)
    XCTAssertEqual(shell?.command, "git status")
    XCTAssertNil(shell?.subtitle)
    XCTAssertEqual(transcript.messages[3].tool?.subtitle, "README.md")
    XCTAssertEqual(Set(transcript.messages.map(\.id)).count, 4, "each piece has its own id")
  }

  func testAToolResultFillsInTheToolThatAskedAndDoesNotAppearAsAMessage() {
    var transcript = transcript(record(1, #"{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}]}"#))
    XCTAssertEqual(transcript.messages.first?.tool?.status, .running)
    transcript.append([record(2, #"{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"a\nb"}],"isError":false}"#)])
    XCTAssertEqual(transcript.messages.count, 1)
    XCTAssertEqual(transcript.messages.first?.tool?.status, .completed)
    XCTAssertEqual(transcript.messages.first?.tool?.output, "a\nb")
  }

  func testAFailedToolIsMarkedFailed() {
    let transcript = transcript(
      record(1, #"{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"false"}}]}"#),
      record(2, #"{"role":"toolResult","toolCallId":"c1","content":"boom","isError":true}"#))
    XCTAssertEqual(transcript.messages.first?.tool?.status, .failed)
  }

  func testRecordsAlreadyHeldAreNeverAppliedTwice() {
    var transcript = transcript(message(1, role: "user", content: #""once""#))
    transcript.append([message(1, role: "user", content: #""once""#), message(2, role: "user", content: #""twice""#)])
    XCTAssertEqual(transcript.messages.map(\.text), ["once", "twice"])
  }

  func testCuttingBackDropsWhatCameAfter() {
    var transcript = transcript(
      record(1, #"{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}]}"#),
      record(2, #"{"role":"toolResult","toolCallId":"c1","content":"done"}"#),
      message(3, role: "user", content: #""third""#))
    transcript.cut(keep: 1)
    XCTAssertEqual(transcript.lastCursor, 1)
    XCTAssertEqual(transcript.messages.count, 1)
    XCTAssertEqual(transcript.messages.first?.tool?.status, .running, "its result was cut too")
    transcript.append([message(2, role: "user", content: #""new second""#)])
    XCTAssertEqual(transcript.messages.last?.text, "new second")
  }

  func testWorkingIsWhatTheHostSays() {
    var transcript = ChatTranscript()
    XCTAssertEqual(transcript.activity, .idle)
    transcript.settle(working: true)
    XCTAssertEqual(transcript.activity, .working)
    transcript.settle(working: false)
    XCTAssertEqual(transcript.activity, .idle)
  }

  func testAMessageWithoutARoleOrBodyIsIgnored() {
    let transcript = transcript(
      ClientRecord(cursor: 1, id: "a", line: #"{"type":"message","id":"a","message":null}"#),
      record(2, #"{"content":"x"}"#),
      message(3, role: "user", content: #""   ""#))
    XCTAssertTrue(transcript.messages.isEmpty)
  }

  // MARK: - Progress

  func testTheReplyBeingWrittenShowsAsItGrowsAndGivesWayToTheWholeMessage() {
    var transcript = ChatTranscript()
    transcript.progress(slot: "message", snapshot: jsonValue(#"{"message":{"role":"assistant","content":[{"type":"text","text":"Che"}]}}"#))
    XCTAssertEqual(transcript.live.map(\.text), ["Che"])
    transcript.progress(slot: "message", snapshot: jsonValue(#"{"message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Checking"}]}}"#))
    XCTAssertEqual(transcript.live.map(\.role), [.thinking, .assistant], "each snapshot is the whole reply so far")
    XCTAssertTrue(transcript.messages.isEmpty, "nothing is part of the conversation until it is recorded")
    transcript.append([message(1, role: "assistant", content: #"[{"type":"text","text":"Checking done"}]"#)])
    XCTAssertTrue(transcript.live.isEmpty)
    XCTAssertEqual(transcript.messages.map(\.text), ["Checking done"])
  }

  func testProgressForAReplyAlreadyRecordedIsNotShownAgain() {
    // Pi stamps a reply when it starts; its progress and its record carry the same stamp.
    let snapshot = jsonValue(#"{"message":{"role":"assistant","timestamp":1792810292069,"content":[{"type":"text","text":"Checking"}]}}"#)
    var transcript = transcript(
      record(1, #"{"role":"assistant","timestamp":1792810292069,"content":[{"type":"text","text":"Checking done"}]}"#))
    transcript.progress(slot: "message", snapshot: snapshot)
    XCTAssertTrue(transcript.live.isEmpty, "a snapshot that arrives after its record, or replayed on reopening")
    XCTAssertEqual(transcript.messages.map(\.text), ["Checking done"])

    // The next reply, stamped later, shows as it is written.
    transcript.progress(
      slot: "message",
      snapshot: jsonValue(#"{"message":{"role":"assistant","timestamp":1792810299000,"content":[{"type":"text","text":"Next"}]}}"#))
    XCTAssertEqual(transcript.live.map(\.text), ["Next"])
  }

  func testAReplyRecordedOnAnOlderPageIsKnownToo() {
    var transcript = transcript(message(2, role: "user", content: #""thanks""#))
    transcript.prepend(older: ChatTranscript(records: [
      record(1, #"{"role":"assistant","timestamp":1792810292069,"content":[{"type":"text","text":"Done"}]}"#)
    ]))
    transcript.progress(
      slot: "message",
      snapshot: jsonValue(#"{"message":{"role":"assistant","timestamp":1792810292069,"content":[{"type":"text","text":"Do"}]}}"#))
    XCTAssertTrue(transcript.live.isEmpty)
  }

  func testAClearedSlotAndAUserMessageAreNoReply() {
    var transcript = ChatTranscript()
    transcript.progress(slot: "message", snapshot: jsonValue(#"{"message":{"role":"user","content":"hi"}}"#))
    XCTAssertTrue(transcript.live.isEmpty)
    transcript.progress(slot: "message", snapshot: jsonValue(#"{"message":{"role":"assistant","content":"partial"}}"#))
    transcript.progress(slot: "message", snapshot: .null)
    XCTAssertTrue(transcript.live.isEmpty)
  }

  func testARunningToolsOutputGrowsUntilItsResultIsRecorded() {
    var transcript = transcript(message(1, role: "assistant", content: #"[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"make"}}]"#))
    transcript.progress(slot: "c1", snapshot: jsonValue(#"{"toolCallId":"c1","partialResult":{"content":[{"type":"text","text":"building"}]}}"#))
    XCTAssertEqual(transcript.messages.first?.tool?.output, "building")
    XCTAssertEqual(transcript.messages.first?.tool?.status, .running)
    transcript.append([record(2, #"{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"built"}],"truncated":true}"#)])
    transcript.progress(slot: "c1", snapshot: jsonValue(#"{"toolCallId":"c1","partialResult":{"content":[{"type":"text","text":"late"}]}}"#))
    XCTAssertEqual(transcript.messages.first?.tool?.output, "built", "a late snapshot does not undo the result")
    XCTAssertEqual(transcript.messages.first?.tool?.outputTruncated, true)
  }

  func testOutputThatCameBeforeTheCallIsRecordedShowsOnIt() {
    var transcript = ChatTranscript()
    transcript.progress(slot: "c1", snapshot: jsonValue(#"{"partialResult":{"content":"early"}}"#))
    transcript.append([message(1, role: "assistant", content: #"[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"make"}}]"#)])
    XCTAssertEqual(transcript.messages.first?.tool?.output, "early")
  }

  func testAQuestionShowsUntilItsSlotIsCleared() {
    var transcript = ChatTranscript()
    transcript.progress(slot: "question", snapshot: jsonValue(#"{"kind":"confirm","title":"Delete the branch?"}"#))
    XCTAssertEqual(transcript.question, ChatQuestion(kind: .confirm, title: "Delete the branch?"))
    transcript.progress(slot: "question", snapshot: .null)
    XCTAssertNil(transcript.question)
    transcript.progress(slot: "question", snapshot: jsonValue(#"{"kind":"something-new"}"#))
    XCTAssertEqual(transcript.question?.kind, .custom, "an unknown kind is answered on the Mac")
  }

  func testSettlingIdleEndsAReplyAndAQuestionLeftOpen() {
    var transcript = ChatTranscript()
    transcript.settle(working: true)
    transcript.progress(slot: "message", snapshot: jsonValue(#"{"message":{"role":"assistant","content":"partial"}}"#))
    transcript.progress(slot: "question", snapshot: jsonValue(#"{"kind":"input"}"#))
    transcript.settle(working: false)
    XCTAssertEqual(transcript.activity, .idle)
    XCTAssertTrue(transcript.live.isEmpty)
    XCTAssertNil(transcript.question)
  }

  func testPicturesWithTheirDataAreShownAndOnesWithoutAreNamed() {
    var transcript = ChatTranscript()
    let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
    transcript.append([message(1, role: "user", content: #"[{"type":"text","text":"look"},{"type":"image","data":"\#(png)","mimeType":"image/png"}]"#)])
    XCTAssertEqual(transcript.messages.first?.text, "look")
    XCTAssertEqual(transcript.messages.first?.images.map(\.source), [.data(Data([0x89, 0x50, 0x4E, 0x47]))])
    XCTAssertEqual(transcript.messages.first?.images.first?.mimeType, "image/png")
    transcript.append([message(2, role: "user", content: #"[{"type":"image","data":"cut…"}]"#)])
    XCTAssertEqual(transcript.messages.last?.text, "[Image attachment]", "a picture cut to cross the wire is named")
    transcript.append([message(3, role: "user", content: #"[{"type":"image","data":"\#(png)"}]"#)])
    XCTAssertEqual(transcript.messages.last?.text, "", "a picture alone is still a message")
    XCTAssertEqual(transcript.messages.last?.images.count, 1)
  }
}
