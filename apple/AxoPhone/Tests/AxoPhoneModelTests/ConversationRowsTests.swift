import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// New messages append: no row moves, or changes identity, as a conversation goes on.
final class ConversationRowsTests: XCTestCase {
  private func plain(_ transcript: ChatTranscript) -> [ConversationReveal.Shown] {
    transcript.messages.map { .init(message: $0, isLive: false, presentation: .plain) }
      + transcript.live.map { .init(message: $0, isLive: true, presentation: .plain) }
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

  private let liveReply = jsonValue(#"{"message":{"role":"assistant","timestamp":1700,"content":[{"type":"text","text":"On it"}]}}"#)

  /// The bug: the reply's first words reached the phone before the person's message was recorded,
  /// so the reply showed above the message, and the two swapped places when the record landed.
  func testAReplyThatArrivesBeforeItsPromptsRecordShowsBelowThePromptAndNothingMoves() {
    let commandId = UUID()
    let prompt = HostWorkbenchModel.PendingPrompt(id: commandId, text: "fix it", state: .sent)
    var transcript = ChatTranscript(records: [said(1, "hello"), said(2, "hi", role: "assistant")])
    let before = ConversationRow.rows(shown: plain(transcript), pending: [prompt])
    XCTAssertEqual(texts(before), ["hello", "hi", "pending: fix it"])

    transcript.settle(working: true)
    transcript.progress(slot: "message", snapshot: liveReply)
    let streaming = ConversationRow.rows(shown: plain(transcript), pending: [prompt])
    XCTAssertEqual(texts(streaming), ["hello", "hi", "pending: fix it", "On it"], "the reply goes under what started it")

    // The record arrives: the message is recorded where it showed, under the same key.
    transcript.append([receipt(3, commandId.uuidString.lowercased()), said(4, "fix it")])
    let recorded = ConversationRow.rows(shown: plain(transcript), pending: [])
    XCTAssertEqual(texts(recorded), ["hello", "hi", "fix it", "On it"])
    XCTAssertEqual(recorded.map(\.id), streaming.map(\.id), "every row kept its identity")
    // And, while the pending one is still on screen for a moment, it shows once.
    XCTAssertEqual(texts(ConversationRow.rows(shown: plain(transcript), pending: [prompt])), ["hello", "hi", "fix it", "On it"])
  }

  func testAMessageSentWhileTheAgentIsBusyWaitsBelowTheReply() {
    let prompt = HostWorkbenchModel.PendingPrompt(id: UUID(), text: "and then", state: .queued, behindReply: true)
    var transcript = ChatTranscript(records: [said(1, "hello")])
    transcript.settle(working: true)
    transcript.progress(slot: "message", snapshot: liveReply)
    XCTAssertEqual(texts(ConversationRow.rows(shown: plain(transcript), pending: [prompt])), ["hello", "On it", "pending: and then"])
  }

  func testRowIdsAreUnique() {
    let prompt = HostWorkbenchModel.PendingPrompt(id: UUID(), text: "fix it", state: .sent)
    var transcript = ChatTranscript(records: [said(1, "hello"), said(2, "hello"), said(3, "hi", role: "assistant")])
    transcript.progress(slot: "message", snapshot: liveReply)
    let ids = ConversationRow.rows(shown: plain(transcript), pending: [prompt]).map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "\(ids)")
  }
}
