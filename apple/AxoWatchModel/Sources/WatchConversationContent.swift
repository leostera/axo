import AxoPhoneModel
import AxoProtocol

/// The same two-sided conversation as the phone, without tool/reasoning rows or empty gaps.
/// Pending and queued prompts are still the person's messages, not status-only placeholders.
public enum WatchConversationContent: Equatable {
  case assistant(String)
  case user(text: String, status: String?)

  public init?(_ row: ConversationRow) {
    switch row {
    case .message(let shown):
      let message = shown.message
      let text = message.text.isEmpty && !message.images.isEmpty ? "Image attached" : message.text
      guard !text.isEmpty else { return nil }
      switch message.role {
      case .user: self = .user(text: text, status: nil)
      case .assistant: self = .assistant(text)
      case .thinking, .tool: return nil
      }
    case .pending(let prompt):
      let status: String
      switch prompt.state {
      case .sending: status = "Sending…"
      case .sent: status = "Sent"
      case .queued: status = Self.queuedLabel(prompt.delivery)
      case .waitingForPi: status = "Waiting for the agent…"
      case .uncertain: status = "Checking delivery…"
      }
      self = .user(text: Self.text(prompt.text, attachments: prompt.attachments.map(\.name)), status: status)
    case .queued(let prompt):
      self = .user(text: Self.text(prompt.text, attachments: prompt.attachments), status: Self.queuedLabel(prompt.delivery))
    }
  }

  private static func text(_ text: String, attachments: [String]) -> String {
    ([text] + attachments.map { "📎 " + $0 }).filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func queuedLabel(_ delivery: PromptDelivery) -> String {
    switch delivery {
    case .interrupt: "Answered next"
    case .steer: "At the agent’s next step"
    case .followUp: "After the current reply"
    }
  }
}
