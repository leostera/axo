import AxoProtocol
import XCTest
@testable import AxoPhoneModel
@testable import AxoWatchModel

final class WatchConversationContentTests: XCTestCase {
  private func message(_ role: ChatMessage.Role, text: String) -> ConversationRow {
    .message(.init(message: ChatMessage(id: "test", role: role, text: text, blocks: [], timestamp: nil, tool: nil),
      isLive: false, presentation: .plain))
  }

  func testBothSidesKeepTheirWordsAndRoles() {
    XCTAssertEqual(WatchConversationContent(message(.user, text: "My question")), .user(text: "My question", status: nil))
    XCTAssertEqual(WatchConversationContent(message(.assistant, text: "The answer")), .assistant("The answer"))
  }

  func testHiddenReasoningToolsAndEmptyMessagesDoNotCreateBlankRows() {
    XCTAssertNil(WatchConversationContent(message(.thinking, text: "hidden")))
    XCTAssertNil(WatchConversationContent(message(.tool, text: "hidden")))
    XCTAssertNil(WatchConversationContent(message(.assistant, text: "")))
  }

  func testQueuedAndSendingMessagesAreUserBubblesNotJustStatusLabels() {
    let pending = HostWorkbenchModel.PendingPrompt(id: UUID(), text: "Keep my question visible", state: .sending)
    XCTAssertEqual(WatchConversationContent(.pending(pending)), .user(text: pending.text, status: "Sending…"))
    let queued = QueuedPrompt(commandId: "test", delivery: .followUp, text: "A follow-up while busy", attachments: [])
    XCTAssertEqual(WatchConversationContent(.queued(queued)), .user(text: queued.text, status: "After the current reply"))
  }
}
