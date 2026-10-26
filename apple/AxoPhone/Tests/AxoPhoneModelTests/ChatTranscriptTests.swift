import AxoProtocol
import XCTest

@testable import AxoPhoneModel

final class ChatTranscriptTests: XCTestCase {
  private let stream = UUID()

  private func event(_ sequence: UInt64, _ name: String, _ json: String = "null") -> PiEventRecord {
    PiEventRecord(
      streamId: stream, sequence: sequence, name: name,
      data: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
  }

  private func message(_ sequence: UInt64, role: String, content: String) -> PiEventRecord {
    event(sequence, "message.end", #"{"message":{"role":"\#(role)","content":\#(content)}}"#)
  }

  func testWholeMessagesBecomeTheConversationInOrder() {
    var transcript = ChatTranscript()
    transcript.apply(message(1, role: "user", content: #""hello""#))
    transcript.apply(message(2, role: "assistant", content: #"[{"type":"text","text":"Hi there"}]"#))
    XCTAssertEqual(transcript.messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(transcript.messages.map(\.text), ["hello", "Hi there"])
  }

  func testTextBlocksJoinAndImagesAreNamedNotShown() {
    var transcript = ChatTranscript()
    transcript.apply(message(1, role: "user", content: #"[{"type":"text","text":"look"},{"type":"image"},{"type":"text","text":"at this"}]"#))
    XCTAssertEqual(transcript.messages.first?.text, "look\n[Image attachment]\nat this")
  }

  func testSystemMessagesAndBareToolResultsAreNotShown() {
    var transcript = ChatTranscript()
    transcript.apply(message(1, role: "toolResult", content: #""output""#))
    transcript.apply(message(2, role: "system", content: #""setup""#))
    XCTAssertTrue(transcript.messages.isEmpty)
  }

  func testAReplyKeepsPiOrderReasoningWordsThenTools() {
    var transcript = ChatTranscript()
    transcript.apply(event(1, "message.end", """
      {"message":{"role":"assistant","timestamp":1792810292069,"content":[
        {"type":"thinking","thinking":"Let me look"},
        {"type":"text","text":"Checking"},{"type":"text","text":"the repo"},
        {"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"git status","timeout":10}},
        {"type":"toolCall","id":"c2","name":"read","arguments":{"path":"README.md"}}]}}
      """))
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
    var transcript = ChatTranscript()
    transcript.apply(event(1, "message.end", #"{"message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}]}}"#))
    XCTAssertEqual(transcript.messages.first?.tool?.status, .running)
    transcript.apply(event(2, "message.end", #"{"message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"a\nb"}],"isError":false}}"#))
    XCTAssertEqual(transcript.messages.count, 1)
    XCTAssertEqual(transcript.messages.first?.tool?.status, .completed)
    XCTAssertEqual(transcript.messages.first?.tool?.output, "a\nb")
  }

  func testAFailedToolIsMarkedFailed() {
    var transcript = ChatTranscript()
    transcript.apply(event(1, "message.end", #"{"message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"false"}}]}}"#))
    transcript.apply(event(2, "message.end", #"{"message":{"role":"toolResult","toolCallId":"c1","content":"boom","isError":true}}"#))
    XCTAssertEqual(transcript.messages.first?.tool?.status, .failed)
  }

  func testAResultThatArrivedLiveStillAnswersAToolReadFromHistory() {
    var transcript = ChatTranscript()
    transcript.apply(event(2, "message.end", #"{"message":{"role":"toolResult","toolCallId":"c1","content":"done","isError":false}}"#))
    transcript.merge(history: [
      event(1, "message.end", #"{"message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}]}}"#)
    ])
    XCTAssertEqual(transcript.messages.first?.tool?.status, .completed)
    XCTAssertEqual(transcript.messages.first?.tool?.output, "done")
  }

  func testAResultThatArrivesBeforeItsCallStillAnswersItWhenTheCallArrives() {
    var transcript = ChatTranscript()
    transcript.apply(event(2, "message.end", #"{"message":{"role":"toolResult","toolCallId":"c1","content":"done","isError":false}}"#))
    transcript.apply(event(1, "message.end", #"{"message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}]}}"#))
    XCTAssertEqual(transcript.messages.first?.tool?.status, .completed)
  }

  func testAResultOlderThanItsCallIsHeldUntilTheCallIsRead() {
    // Older pages are read last, so a result can be read before the call that made it.
    var transcript = ChatTranscript()
    transcript.merge(history: [event(2, "message.end", #"{"message":{"role":"toolResult","toolCallId":"c1","content":"done","isError":false}}"#)])
    XCTAssertTrue(transcript.messages.isEmpty)
    transcript.merge(history: [
      event(1, "message.end", #"{"message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}]}}"#),
      event(2, "message.end", #"{"message":{"role":"toolResult","toolCallId":"c1","content":"done","isError":false}}"#),
    ])
    XCTAssertEqual(transcript.messages.first?.tool?.status, .completed)
  }

  func testRepeatingAnEventNeverRepeatsAMessage() {
    var transcript = ChatTranscript()
    let said = message(1, role: "user", content: #""once""#)
    transcript.apply(said)
    transcript.apply(said)
    XCTAssertEqual(transcript.messages.count, 1)
    // The same sequence in a different stream is a different event.
    transcript.apply(PiEventRecord(streamId: UUID(), sequence: 1, name: "message.end", data: said.data))
    XCTAssertEqual(transcript.messages.count, 2)
  }

  func testPiWorkingFollowsTheAgentEvents() {
    var transcript = ChatTranscript()
    XCTAssertEqual(transcript.activity, .idle)
    transcript.apply(event(1, "agent.start"))
    XCTAssertEqual(transcript.activity, .working)
    transcript.apply(event(2, "turn.end"))
    XCTAssertEqual(transcript.activity, .working)
    transcript.apply(event(3, "agent.settled"))
    XCTAssertEqual(transcript.activity, .idle)
    transcript.apply(event(4, "agent.start"))
    transcript.apply(event(5, "agent.end"))
    XCTAssertEqual(transcript.activity, .idle)
  }

  func testHistoryGoesFirstAndLiveMessagesNotInItStayAfter() {
    var transcript = ChatTranscript()
    // Live events arrive while history is still loading.
    transcript.apply(message(3, role: "assistant", content: #""live three""#))
    transcript.apply(message(4, role: "user", content: #""live four""#))
    transcript.apply(event(5, "agent.start"))
    transcript.merge(history: [
      message(1, role: "user", content: #""old one""#),
      message(2, role: "assistant", content: #""old two""#),
      message(3, role: "assistant", content: #""live three""#),
    ])
    XCTAssertEqual(transcript.messages.map(\.text), ["old one", "old two", "live three", "live four"])
    XCTAssertEqual(transcript.activity, .working, "history does not say Pi stopped")
    transcript.apply(message(4, role: "user", content: #""live four""#))
    XCTAssertEqual(transcript.messages.count, 4, "and a replay after the merge adds nothing")
  }

  func testAMessageWithoutARoleOrBodyIsIgnored() {
    var transcript = ChatTranscript()
    transcript.apply(event(1, "message.end", "null"))
    transcript.apply(event(2, "message.end", #"{"message":{"content":"x"}}"#))
    transcript.apply(message(3, role: "user", content: #""   ""#))
    XCTAssertTrue(transcript.messages.isEmpty)
  }
}
