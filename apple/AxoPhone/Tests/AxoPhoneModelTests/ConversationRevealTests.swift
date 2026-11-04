import XCTest

@testable import AxoPhoneModel

@MainActor
final class ConversationRevealTests: XCTestCase {
  private func message(_ id: String, _ role: ChatMessage.Role, _ text: String = "Words", reply: Int64? = nil, piece: Int = 0) -> ChatMessage {
    ChatMessage(
      id: id, role: role, text: text, blocks: [], timestamp: nil, tool: nil,
      replyKey: ChatMessage.replyKey(timestamp: reply, index: piece))
  }

  private func live(_ text: String, reply: Int64, piece: Int = 0) -> ChatMessage {
    message("live#\(piece)", .assistant, text, reply: reply, piece: piece)
  }

  private func presentations(_ shown: [ConversationReveal.Shown]) -> [String: ConversationReveal.Presentation] {
    Dictionary(uniqueKeysWithValues: shown.map { ($0.message.key, $0.presentation) })
  }

  func testWhatTheChatOpenedWithIsHistoryAndJustAppears() {
    let reveal = ConversationReveal()
    let shown = reveal.shown(
      sessionId: "a", messages: [message("1", .user), message("2", .assistant, reply: 10)], live: [])
    XCTAssertEqual(shown.map(\.presentation), [.plain, .plain])
  }

  func testAReplySeenLiveIsLetOutAndCarriedOnThroughItsRecord() {
    let reveal = ConversationReveal()
    _ = reveal.shown(sessionId: "a", messages: [message("1", .user)], live: [])
    var shown = reveal.shown(sessionId: "a", messages: [message("1", .user)], live: [live("Hel", reply: 20)])
    XCTAssertEqual(shown.last?.presentation, .reveal(final: false, hurry: false), "still being written")

    reveal.reveal("reply:20#0", upTo: 3)
    shown = reveal.shown(sessionId: "a", messages: [message("1", .user), message("2", .assistant, "Hello there", reply: 20)], live: [])
    XCTAssertEqual(shown.last?.message.key, "reply:20#0", "the record is the same reply")
    XCTAssertEqual(shown.last?.presentation, .reveal(final: true, hurry: false))
    XCTAssertEqual(reveal.revealed("reply:20#0"), 3, "it goes on from where it was")

    reveal.finished("reply:20#0")
    shown = reveal.shown(sessionId: "a", messages: [message("1", .user), message("2", .assistant, "Hello there", reply: 20)], live: [])
    XCTAssertEqual(shown.last?.presentation, .plain, "all out, it shows as it is")
  }

  func testWhatFollowsAReplyWaitsUntilAllOfItIsOut() {
    let reveal = ConversationReveal()
    _ = reveal.shown(sessionId: "a", messages: [message("1", .user)], live: [])
    let messages = [
      message("1", .user),
      message("2", .assistant, "Let me look", reply: 30, piece: 0),
      message("2#1", .tool, "", reply: 30, piece: 1),
    ]
    var shown = reveal.shown(sessionId: "a", messages: messages, live: [])
    XCTAssertEqual(shown.map(\.message.id), ["1", "2"], "the tool waits for the words before it")
    XCTAssertEqual(shown.last?.presentation, .reveal(final: true, hurry: true), "and the words hurry, with something waiting")
    reveal.finished("reply:30#0")
    shown = reveal.shown(sessionId: "a", messages: messages, live: [])
    XCTAssertEqual(shown.map(\.message.id), ["1", "2", "2#1"])
    XCTAssertEqual(shown.last?.presentation, .rise, "anything else rises in")
  }

  func testABatchCaughtUpAtOnceJustAppears() {
    let reveal = ConversationReveal()
    _ = reveal.shown(sessionId: "a", messages: [message("1", .user)], live: [])
    let shown = reveal.shown(
      sessionId: "a",
      messages: [message("1", .user), message("2", .assistant, reply: 40), message("3", .user), message("4", .assistant, reply: 41)],
      live: [])
    XCTAssertEqual(shown.map(\.presentation), [.plain, .plain, .plain, .plain], "written while nobody watched")
  }

  func testThePersonsOwnMessageDoesNotRiseItWasOnScreenAsPending() {
    let reveal = ConversationReveal()
    _ = reveal.shown(sessionId: "a", messages: [message("1", .assistant, reply: 1)], live: [])
    let shown = reveal.shown(sessionId: "a", messages: [message("1", .assistant, reply: 1), message("2", .user)], live: [])
    XCTAssertEqual(presentations(shown)["2"], .plain)
  }

  func testOlderPagesReadInAboveJustAppear() {
    let reveal = ConversationReveal()
    _ = reveal.shown(sessionId: "a", messages: [message("5", .user), message("6", .assistant, reply: 60)], live: [])
    let shown = reveal.shown(
      sessionId: "a", messages: [message("3", .user), message("4", .assistant, reply: 40), message("5", .user), message("6", .assistant, reply: 60)],
      live: [])
    XCTAssertEqual(shown.map(\.presentation), [.plain, .plain, .plain, .plain])
  }

  func testARiseIsPlayedOnceEvenWhenTheRowIsMadeAgain() {
    let reveal = ConversationReveal()
    _ = reveal.shown(sessionId: "a", messages: [message("1", .user)], live: [])
    let messages = [message("1", .user), message("2", .tool, "", reply: 70)]
    XCTAssertEqual(reveal.shown(sessionId: "a", messages: messages, live: []).last?.presentation, .rise)
    reveal.rose("reply:70#0")
    XCTAssertEqual(reveal.shown(sessionId: "a", messages: messages, live: []).last?.presentation, .plain)
  }

  func testAnotherChatStartsAfresh() {
    let reveal = ConversationReveal()
    _ = reveal.shown(sessionId: "a", messages: [message("1", .user)], live: [])
    let shown = reveal.shown(sessionId: "b", messages: [message("9", .user), message("10", .assistant, reply: 90)], live: [])
    XCTAssertEqual(shown.map(\.presentation), [.plain, .plain])
  }

  // MARK: - Pace

  func testWordsComeOutWholeAtAnEvenPace() {
    let text = "The quick brown fox jumps over the lazy dog"
    let first = RevealPace.next(shown: 0, of: text, after: 0.032)
    XCTAssertEqual(first, 3, "about three characters at 90 a second, rounded out to the word: \"The\"")
    let later = RevealPace.next(shown: first, of: text, after: 0.1)
    XCTAssertEqual(String(text.prefix(later)), "The quick brown", "never half a word")
    XCTAssertEqual(RevealPace.next(shown: text.count, of: text, after: 1), text.count)
  }

  func testAReplyWithMoreWaitingBehindItHurries() {
    let text = String(repeating: "word ", count: 50)
    XCTAssertGreaterThan(
      RevealPace.next(shown: 0, of: text, after: 0.032, hurry: true), RevealPace.next(shown: 0, of: text, after: 0.032))
  }

  func testABacklogShrinksQuicklyRatherThanTrailingAtTheBasePace() {
    let text = String(repeating: "word ", count: 400)
    var shown = 0
    var elapsed = 0.0
    var afterCatchUp = 0
    while shown < text.count, elapsed < 10 {
      shown = RevealPace.next(shown: shown, of: text, after: 0.032)
      elapsed += 0.032
      if afterCatchUp == 0, elapsed >= RevealPace.catchUp { afterCatchUp = shown }
    }
    XCTAssertEqual(shown, text.count)
    XCTAssertGreaterThan(afterCatchUp, text.count / 2, "most of it is out within the catch-up time")
    XCTAssertLessThan(elapsed, 3, "2000 characters do not take 22 seconds at the base pace")
  }
}
