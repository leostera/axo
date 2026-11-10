import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// A tool shows what it was given, and the tools used one after another are a block headed by what
/// they did. As on the web.
@MainActor
final class ToolGroupsTests: XCTestCase {
  private func call(_ id: String, _ name: String, _ arguments: String) -> String {
    #"{"type":"toolCall","id":"\#(id)","name":"\#(name)","arguments":\#(arguments)}"#
  }

  private func tools(_ calls: String...) -> [ToolActivity] {
    let record = piRecord(1, message: #"{"role":"assistant","content":[\#(calls.joined(separator: ","))]}"#)
    return ChatTranscript(records: [record]).messages.compactMap(\.tool)
  }

  func testAToolShowsWhatItWasGiven() {
    let all = tools(
      call("a", "bash", #"{"command":"ls -la"}"#),
      call("b", "codemode", #"{"code":"return 1;"}"#),
      call("c", "edit", #"{"path":"a.ts","edits":[{"oldText":"a\nb","newText":"c"}]}"#),
      call("d", "write", #"{"path":"a.ts","content":"x"}"#),
      call("e", "read", #"{"path":"a.ts","offset":5,"limit":10}"#),
      call("f", "mcp", #"{"server":"linear","search":""}"#))
    XCTAssertEqual(all.count, 6)
    let (shell, script, edit, write, read, other) = (all[0], all[1], all[2], all[3], all[4], all[5])
    XCTAssertEqual(shell.input, ToolInput(kind: .command, text: "ls -la"))
    XCTAssertEqual(script.input, ToolInput(kind: .code, text: "return 1;"))
    XCTAssertEqual(edit.input, ToolInput(kind: .diff, text: "-a\n-b\n+c"))
    XCTAssertEqual(write.input, ToolInput(kind: .text, text: "x"))
    XCTAssertNil(read.input, "a read says it all in its subtitle")
    XCTAssertEqual(read.subtitle, "a.ts · lines 5–14")
    XCTAssertEqual(other.input, ToolInput(kind: .arguments, text: "{\n  \"server\": \"linear\"\n}"))
    XCTAssertEqual(script.preview, "return 1;")
    XCTAssertEqual(shell.preview, "ls -la")
  }

  func testABlockIsHeadedByWhatItDid() {
    let reads = tools(
      call("a", "read", #"{"path":"a.ts"}"#), call("b", "read", #"{"path":"b.ts"}"#), call("c", "bash", #"{"command":"ls"}"#))
    XCTAssertEqual(ToolGroupPlace.title(of: reads), "Read 2 files, ran a command")
    let edits = tools(
      call("a", "edit", #"{"path":"a.ts","edits":[]}"#), call("b", "edit", #"{"path":"a.ts","edits":[]}"#),
      call("c", "codemode", #"{"code":"1"}"#), call("d", "codemode", #"{"code":"2"}"#))
    XCTAssertEqual(ToolGroupPlace.title(of: edits), "Edited a file, ran 2 scripts")
    let other = tools(call("a", "mcp", "{}"), call("b", "mcp", "{}"), call("c", "mcp", "{}"))
    XCTAssertEqual(ToolGroupPlace.title(of: other), "Used mcp 3 times")
  }

  func testTheFeedTellsEachToolItsPlaceInItsBlock() {
    let records = [
      piRecord(1, message: #"{"role":"user","content":"go"}"#),
      piRecord(
        2,
        message: #"{"role":"assistant","content":[{"type":"text","text":"Looking."},\#(call("a", "read", #"{"path":"a.ts"}"#)),\#(call("b", "bash", #"{"command":"ls"}"#))]}"#),
      piRecord(3, message: #"{"role":"assistant","content":[{"type":"text","text":"One more."},\#(call("c", "bash", #"{"command":"pwd"}"#))]}"#),
    ]
    let feed = ConversationFeed(ticks: false)
    feed.update(transcript: ChatTranscript(records: records), pending: [])
    feed.opened()
    XCTAssertEqual(feed.items.map(\.group), [
      nil, nil,
      ToolGroupPlace(first: true, last: false, title: "Read a file, ran a command"),
      ToolGroupPlace(first: false, last: true, title: nil),
      nil,
      ToolGroupPlace(first: true, last: true, title: nil),
    ])
  }

  func testAToolJoiningABlockChangesTheRowAboveIt() {
    let first = piRecord(1, message: #"{"role":"assistant","content":[\#(call("a", "bash", #"{"command":"ls"}"#))]}"#)
    let feed = ConversationFeed(ticks: false)
    var grew: Set<String> = []
    feed.changed = { grew.formUnion($0) }
    feed.update(transcript: ChatTranscript(records: [first]), pending: [])
    feed.opened()
    let above = feed.items[0]
    XCTAssertEqual(above.group, ToolGroupPlace(first: true, last: true, title: nil))
    grew = []
    let second = piRecord(2, message: #"{"role":"assistant","content":[\#(call("b", "read", #"{"path":"a.ts"}"#))]}"#)
    feed.update(transcript: ChatTranscript(records: [first, second]), pending: [])
    XCTAssertEqual(above.group, ToolGroupPlace(first: true, last: false, title: "Ran a command, read a file"))
    XCTAssertTrue(grew.contains(above.id), "the list sizes the row it joined")
  }

  func testOpeningARowSizesItAtOnceAndAsksTheListToHoldIt() {
    let record = piRecord(1, message: #"{"role":"assistant","content":[\#(call("a", "bash", #"{"command":"ls"}"#))]}"#)
    let feed = ConversationFeed(ticks: false)
    feed.update(transcript: ChatTranscript(records: [record]), pending: [])
    feed.opened()
    let row = feed.items[0]
    var told: (grew: Set<String>, held: String?)?
    feed.changed = { [weak feed] grew in told = (grew, feed?.held) }
    feed.toggleOpen(row.id)
    XCTAssertTrue(row.open)
    XCTAssertEqual(told?.grew, [row.id], "the list sizes it in the same turn")
    XCTAssertEqual(told?.held, row.id, "and keeps it where it is")
    XCTAssertNil(feed.held, "read once")
    // It stays open as the transcript changes around it.
    feed.update(transcript: ChatTranscript(records: [record]), pending: [])
    XCTAssertTrue(row.open)
  }
}
