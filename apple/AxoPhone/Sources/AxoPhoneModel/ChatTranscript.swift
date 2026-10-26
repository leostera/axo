import AxoProtocol
import Foundation

/// One thing in the conversation.
public struct ChatMessage: Identifiable, Equatable, Sendable {
  public enum Role: Equatable, Sendable {
    case user
    case assistant
    /// A tool Pi is using, shown as a quiet line, not a message.
    case tool
  }

  /// Stable across reloads: the event that made it.
  public let id: String
  public let role: Role
  public let text: String
}

/// A conversation as Pi's events tell it. Only whole messages count (`message.end`); the rest of
/// the stream says whether Pi is working. Replaying an event, or reading history that overlaps
/// what already arrived live, never repeats a message.
public struct ChatTranscript: Equatable, Sendable {
  public enum Activity: Equatable, Sendable {
    case idle
    case working
  }

  public private(set) var messages: [ChatMessage] = []
  public private(set) var activity: Activity = .idle
  private var known: Set<String> = []

  public init() {}

  public mutating func apply(_ record: PiEventRecord) {
    switch record.name {
    case "agent.start": activity = .working
    case "agent.end", "agent.settled": activity = .idle
    case "message.end":
      let id = Self.id(of: record)
      guard !known.contains(id) else { return }
      for (index, message) in Self.messages(from: record).enumerated() {
        known.insert(id)
        messages.append(ChatMessage(id: index == 0 ? id : "\(id)#\(index)", role: message.role, text: message.text))
      }
    default: break
    }
  }

  /// Puts stored history first, keeping anything that arrived live and is not in it.
  public mutating func merge(history: [PiEventRecord]) {
    var rebuilt = ChatTranscript()
    for record in history { rebuilt.apply(record) }
    let inHistory = Set(rebuilt.messages.map(\.id))
    let live = messages.filter { !inHistory.contains($0.id) }
    messages = rebuilt.messages + live
    known = Set(messages.map { String($0.id.split(separator: "#")[0]) })
    // History says nothing about whether Pi is working right now; keep what live events said.
  }

  private static func id(of record: PiEventRecord) -> String { "\(record.streamId.uuidString.lowercased()):\(record.sequence)" }

  private static func messages(from record: PiEventRecord) -> [(role: ChatMessage.Role, text: String)] {
    guard let message = record.data["message"], let role = message["role"]?.stringValue else { return [] }
    let content = message["content"]
    switch role {
    case "user":
      let text = visibleText(content)
      return text.isEmpty ? [] : [(.user, text)]
    case "assistant":
      var result: [(role: ChatMessage.Role, text: String)] = []
      let text = visibleText(content)
      if !text.isEmpty { result.append((.assistant, text)) }
      let tools = toolNames(content) + (message["toolCalls"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
      if !tools.isEmpty { result.append((.tool, "Using \(Array(NSOrderedSet(array: tools)).compactMap { $0 as? String }.joined(separator: ", "))")) }
      return result
    default:
      return []
    }
  }

  private static func visibleText(_ content: JSONValue?) -> String {
    if let text = content?.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    return (content?.arrayValue ?? []).compactMap { block -> String? in
      switch block["type"]?.stringValue {
      case "text": block["text"]?.stringValue
      case "image": "[Image attachment]"
      default: nil
      }
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func toolNames(_ content: JSONValue?) -> [String] {
    (content?.arrayValue ?? []).compactMap { block in
      block["type"]?.stringValue == "toolCall" ? block["name"]?.stringValue : nil
    }
  }
}
