import AxoProtocol
import Observation
import XCTest

@testable import AxoPhoneModel

/// The conversation's rows are made once and kept: a change changes the rows it touches in place,
/// new rows go on the end, and the list itself changes only when a row is added.
@MainActor
final class ConversationFeedTests: XCTestCase {
  private let stamp: Int64 = 1_792_810_292_069

  private func user(_ cursor: Int64, _ text: String) -> ClientRecord {
    piRecord(cursor, message: #"{"role":"user","content":"\#(text)"}"#)
  }

  private func reply(_ cursor: Int64, _ text: String, stamp: Int64? = nil, tool: Bool = false) -> ClientRecord {
    let call = tool ? #",{"type":"toolCall","id":"c\#(cursor)","name":"bash","arguments":{"command":"ls"}}"# : ""
    let time = stamp.map { #","timestamp":\#($0)"# } ?? ""
    return piRecord(cursor, message: #"{"role":"assistant"\#(time),"content":[{"type":"text","text":"\#(text)"}\#(call)]}"#)
  }

  private func words(_ text: String, stamp: Int64, tool: Bool = false) -> JSONValue {
    let call = tool ? #",{"type":"toolCall","id":"live","name":"bash","arguments":{"command":"ls"}}"# : ""
    return jsonValue(
      #"{"message":{"role":"assistant","timestamp":\#(stamp),"content":[{"type":"text","text":"\#(text)"}\#(call)]}}"#)
  }

  private func custom(_ cursor: Int64, _ type: String, _ data: String) -> ClientRecord {
    ClientRecord(cursor: cursor, id: "e\(cursor)", line: #"{"type":"custom","id":"e\#(cursor)","customType":"\#(type)","data":\#(data)}"#)
  }

  /// A feed holding a chat that is on screen, with `records` as its history.
  private func opened(_ records: [ClientRecord]) -> (ConversationFeed, ChatTranscript) {
    let feed = ConversationFeed()
    let transcript = ChatTranscript(records: records)
    feed.update(transcript: transcript, pending: [])
    feed.opened()
    return (feed, transcript)
  }

  /// Whether `change` makes the list itself (not a row in it) change.
  private func listChanges(_ feed: ConversationFeed, _ change: () -> Void) -> Bool {
    var changed = false
    withObservationTracking { _ = feed.items } onChange: { changed = true }
    change()
    return changed
  }

  private func ids(_ feed: ConversationFeed) -> [ObjectIdentifier] { feed.items.map(ObjectIdentifier.init) }

  func testAStreamedReplyChangesItsOwnRowAndNotTheList() {
    var (feed, transcript) = opened([user(1, "hi"), reply(2, "Hello")])
    transcript.settle(working: true)
    transcript.progress(slot: "message", snapshot: words("Che", stamp: stamp))
    feed.update(transcript: transcript, pending: [])
    let held = ids(feed)
    XCTAssertEqual(held.count, 3, "the reply's first words add its row")
    for count in 1...20 {
      transcript.progress(slot: "message", snapshot: words("Checking " + String(repeating: "word ", count: count), stamp: stamp))
      XCTAssertFalse(listChanges(feed) { feed.update(transcript: transcript, pending: []) }, "update \(count) left the list alone")
    }
    XCTAssertEqual(ids(feed), held)
    guard case .message(let shown) = feed.items.last?.row else { return XCTFail("the reply") }
    XCTAssertTrue(shown.message.text.hasSuffix("word word"), "the reply's row holds the newest words")
  }

  func testAReplyKeepsItsRowFromItsFirstWordsToItsRecordEvenIfItsWordsAreClearedFirst() {
    var (feed, transcript) = opened([user(1, "hi")])
    transcript.settle(working: true)
    transcript.progress(slot: "message", snapshot: words("Done", stamp: stamp))
    feed.update(transcript: transcript, pending: [])
    let row = feed.items.last
    // The Mac clears the reply being written, and the agent goes idle, before the record arrives.
    transcript.progress(slot: "message", snapshot: .null)
    transcript.settle(working: false)
    XCTAssertFalse(listChanges(feed) { feed.update(transcript: transcript, pending: []) }, "the reply does not blink out")
    XCTAssertTrue(feed.items.last === row)
    transcript.append([reply(2, "Done", stamp: stamp)])
    XCTAssertFalse(listChanges(feed) { feed.update(transcript: transcript, pending: []) }, "its record takes its row")
    XCTAssertTrue(feed.items.last === row)
    guard case .message(let shown) = row?.row else { return XCTFail("the reply") }
    XCTAssertFalse(shown.isLive)
  }

  func testAMessageSentDuringAReplyStaysWhereItWasSent() {
    var (feed, transcript) = opened([user(1, "hi")])
    transcript.settle(working: true)
    transcript.progress(slot: "message", snapshot: words("Looking", stamp: stamp))
    feed.update(transcript: transcript, pending: [])
    let sent = HostWorkbenchModel.PendingPrompt(id: UUID(), text: "also this", state: .queued, behindReply: true)
    feed.update(transcript: transcript, pending: [sent])
    // The reply goes on to call a tool: a new piece, written after the message was sent.
    transcript.progress(slot: "message", snapshot: words("Looking", stamp: stamp, tool: true))
    feed.update(transcript: transcript, pending: [sent])
    // Once its first words are all out.
    feed.finished("reply:\(stamp)#0")
    XCTAssertEqual(feed.items.map(\.id).suffix(3), ["reply:\(stamp)#0", sent.key, "reply:\(stamp)#1"])
  }

  func testAnOlderPageGoesOnTopAndTheRowsHeldStay() {
    var (feed, transcript) = opened([user(3, "third"), reply(4, "fourth")])
    let held = ids(feed)
    transcript.prepend(older: ChatTranscript(records: [user(1, "first"), reply(2, "second")]))
    feed.update(transcript: transcript, pending: [])
    XCTAssertEqual(feed.items.count, 4)
    XCTAssertEqual(Array(ids(feed).suffix(2)), held, "the rows held are the same rows, below the page")
    XCTAssertEqual(feed.items.first?.id, "e1")
  }

  func testAQueuedPromptBecomesItsMessageInTheSameRow() {
    let command = UUID().uuidString.lowercased()
    var (feed, transcript) = opened([user(1, "hi")])
    transcript.append([custom(2, "axo.command.queued", #"{"commandId":"\#(command)","delivery":"followUp","text":"later"}"#)])
    feed.update(transcript: transcript, pending: [])
    let row = feed.items.last
    transcript.append([custom(3, "axo.command", #"{"commandId":"\#(command)"}"#), user(4, "later")])
    XCTAssertFalse(listChanges(feed) { feed.update(transcript: transcript, pending: []) })
    XCTAssertTrue(feed.items.last === row)
    guard case .message = row?.row else { return XCTFail("the queued prompt is its message now") }
  }

  func testWhatFollowsAReplyBeingLetOutIsAddedOnceItIsOut() {
    var (feed, transcript) = opened([user(1, "hi")])
    transcript.append([reply(2, "A long answer", stamp: stamp)])
    feed.update(transcript: transcript, pending: [])
    transcript.append([user(3, "thanks")])
    feed.update(transcript: transcript, pending: [])
    XCTAssertEqual(feed.items.map(\.id), ["e1", "reply:\(stamp)#0"], "the person's next message waits for the reply's words")
    let held = ids(feed)
    feed.finished("reply:\(stamp)#0")
    XCTAssertEqual(Array(ids(feed).prefix(2)), held)
    XCTAssertEqual(feed.items.map(\.id), ["e1", "reply:\(stamp)#0", "e3"], "and is added after it")
  }

  func testACutStartsTheRowsAgain() {
    var (feed, transcript) = opened([user(1, "one"), reply(2, "two"), user(3, "three")])
    let first = feed.items.first
    transcript.cut(keep: 1)
    feed.update(transcript: transcript, pending: [])
    XCTAssertEqual(feed.items.map(\.id), ["e1"])
    XCTAssertFalse(feed.items.first === first)
  }

  func testAMessageTakenBackGoes() {
    var (feed, transcript) = opened([user(1, "hi")])
    let sent = HostWorkbenchModel.PendingPrompt(id: UUID(), text: "oops", state: .uncertain)
    feed.update(transcript: transcript, pending: [sent])
    XCTAssertEqual(feed.items.count, 2)
    feed.update(transcript: transcript, pending: [])
    XCTAssertEqual(feed.items.map(\.id), ["e1"])
    _ = transcript
  }

  /// A busy chat's whole run, step by step: every row held stays where it was, and the new ones
  /// are only ever added on the end.
  func testThroughARunRowsAreOnlyAddedOnTheEnd() {
    var (feed, transcript) = opened([user(1, "start")])
    var pending: [HostWorkbenchModel.PendingPrompt] = []
    var cursor: Int64 = 1
    func step(_ name: String, _ change: () -> Void) {
      let before = ids(feed)
      change()
      feed.update(transcript: transcript, pending: pending)
      let after = ids(feed)
      XCTAssertEqual(Array(after.prefix(before.count)), before, "\(name): the rows held stay, in order, at the top")
    }
    for turn in 0..<4 {
      let stamp = self.stamp + Int64(turn)
      let prompt = HostWorkbenchModel.PendingPrompt(id: UUID(), text: "do \(turn)", state: .sent)
      step("send \(turn)") { pending.append(prompt) }
      step("receipt and message \(turn)") {
        cursor += 2
        transcript.append([
          custom(cursor - 1, "axo.command", #"{"commandId":"\#(prompt.id.uuidString.lowercased())"}"#), user(cursor, "do \(turn)"),
        ])
        pending.removeAll { $0.id == prompt.id }
        transcript.settle(working: true)
      }
      for count in 1...5 {
        step("words \(turn).\(count)") {
          transcript.progress(slot: "message", snapshot: words(String(repeating: "w ", count: count), stamp: stamp, tool: count > 3))
        }
      }
      step("cleared \(turn)") { transcript.progress(slot: "message", snapshot: .null) }
      step("record \(turn)") {
        cursor += 1
        transcript.append([reply(cursor, String(repeating: "w ", count: 5), stamp: stamp, tool: true)])
        transcript.settle(working: false)
      }
      feed.finished("reply:\(stamp)#0")
    }
    XCTAssertEqual(feed.items.count, 1 + 4 * 3, "each turn: its message, the reply's words and its tool")
  }
}
