import AxoProtocol
import Foundation

/// A tool Pi used: what it was asked to do and, once it has answered, how that went.
public struct ToolActivity: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case shell, edit, file, search, generic }
  public enum Status: Equatable, Sendable { case running, completed, failed }

  /// Pi's id for the call; the result names it.
  public let callID: String?
  public let name: String
  public let kind: Kind
  /// The file or pattern the tool works on.
  public let subtitle: String?
  /// What was run: the shell command, or nothing for tools that have no such text.
  public let command: String?
  public fileprivate(set) var status: Status
  public fileprivate(set) var output: String

  static func kind(of name: String) -> Kind {
    switch name {
    case "bash": .shell
    case "edit", "write": .edit
    case "read": .file
    case "grep", "find", "ls", "search": .search
    default: .generic
    }
  }

  fileprivate mutating func fill(_ result: ToolResult) {
    status = result.status
    output = result.output
  }
}

/// How a tool call ended, as its result message says.
private struct ToolResult: Equatable, Sendable {
  let status: ToolActivity.Status
  let output: String
}

/// One thing in the conversation.
public struct ChatMessage: Identifiable, Equatable, Sendable {
  public enum Role: Equatable, Sendable {
    case user
    case assistant
    /// What Pi reasoned before answering; shown quietly.
    case thinking
    case tool
  }

  /// Stable across reloads: the event that made it.
  public let id: String
  public let role: Role
  public let text: String
  /// When it happened, in milliseconds since 1970, as Pi recorded it.
  public let timestamp: Int64?
  public fileprivate(set) var tool: ToolActivity?
}

/// A conversation as Pi's events tell it. Only whole messages count (`message.end`); the rest of
/// the stream says whether Pi is working. Replaying an event, or reading history that overlaps
/// what already arrived live, never repeats a message. A tool's result is not a message of its
/// own: it fills in the tool that asked.
public struct ChatTranscript: Equatable, Sendable {
  public enum Activity: Equatable, Sendable {
    case idle
    case working
  }

  public private(set) var messages: [ChatMessage] = []
  public private(set) var activity: Activity = .idle
  private var known: Set<String> = []
  private var results: [String: ToolResult] = [:]

  public init() {}

  public mutating func apply(_ record: PiEventRecord) {
    switch record.name {
    case "agent.start": activity = .working
    case "agent.end", "agent.settled": activity = .idle
    case "message.end":
      let id = Self.id(of: record)
      guard !known.contains(id) else { return }
      guard let message = record.data["message"], let role = message["role"]?.stringValue else { return }
      if role == "toolResult" {
        recordResult(of: message)
        return
      }
      let timestamp = message["timestamp"]?.numberValue.map { Int64($0) }
      for (index, piece) in Self.pieces(of: message, role: role).enumerated() {
        known.insert(id)
        var tool = piece.tool
        if let callID = tool?.callID, let result = results[callID] { tool?.fill(result) }
        messages.append(
          ChatMessage(
            id: index == 0 ? id : "\(id)#\(index)", role: piece.role, text: piece.text,
            timestamp: timestamp, tool: tool))
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
    // A result that arrived live belongs to a tool the history may have recorded as unanswered.
    results.merge(rebuilt.results) { live, _ in live }
    messages = (rebuilt.messages + live).map { message in
      var message = message
      if let callID = message.tool?.callID, let result = results[callID] { message.tool?.fill(result) }
      return message
    }
    known = Set(messages.map { String($0.id.split(separator: "#")[0]) })
    // History says nothing about whether Pi is working right now; keep what live events said.
  }

  private mutating func recordResult(of message: JSONValue) {
    guard let callID = message["toolCallId"]?.stringValue else { return }
    let status: ToolActivity.Status = message["isError"]?.boolValue == true ? .failed : .completed
    let result = ToolResult(status: status, output: Self.visibleText(message["content"]))
    results[callID] = result
    if let index = messages.firstIndex(where: { $0.tool?.callID == callID }) {
      messages[index].tool?.fill(result)
    }
  }

  private static func id(of record: PiEventRecord) -> String { "\(record.streamId.uuidString.lowercased()):\(record.sequence)" }

  private struct Piece {
    let role: ChatMessage.Role
    let text: String
    var tool: ToolActivity?
  }

  private static func pieces(of message: JSONValue, role: String) -> [Piece] {
    let content = message["content"]
    switch role {
    case "user":
      let text = visibleText(content)
      return text.isEmpty ? [] : [Piece(role: .user, text: text, tool: nil)]
    case "assistant":
      var pieces = assistantBlocks(content)
      // Some events list the calls apart from the content.
      for call in message["toolCalls"]?.arrayValue ?? [] {
        if let tool = toolActivity(from: call) { pieces.append(Piece(role: .tool, text: "", tool: tool)) }
      }
      return pieces
    default:
      return []
    }
  }

  /// The reply in the order Pi wrote it: reasoning, words, then the tools it reached for.
  private static func assistantBlocks(_ content: JSONValue?) -> [Piece] {
    if let text = content?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
      return text.isEmpty ? [] : [Piece(role: .assistant, text: text, tool: nil)]
    }
    var pieces: [Piece] = []
    var words: [String] = []
    func flushWords() {
      let text = words.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { pieces.append(Piece(role: .assistant, text: text, tool: nil)) }
      words = []
    }
    for block in content?.arrayValue ?? [] {
      switch block["type"]?.stringValue {
      case "text":
        if let text = block["text"]?.stringValue { words.append(text) }
      case "image":
        words.append("[Image attachment]")
      case "thinking":
        flushWords()
        let text = block["thinking"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { pieces.append(Piece(role: .thinking, text: text, tool: nil)) }
      case "toolCall":
        flushWords()
        if let tool = toolActivity(from: block) { pieces.append(Piece(role: .tool, text: "", tool: tool)) }
      default:
        break
      }
    }
    flushWords()
    return pieces
  }

  private static func toolActivity(from call: JSONValue) -> ToolActivity? {
    guard let name = call["name"]?.stringValue else { return nil }
    let arguments = call["arguments"]
    let kind = ToolActivity.kind(of: name)
    let subtitle = ["path", "file_path", "pattern", "query"].lazy.compactMap { arguments?[$0]?.stringValue }.first
    return ToolActivity(
      callID: call["id"]?.stringValue, name: name, kind: kind,
      subtitle: kind == .shell ? nil : subtitle,
      command: kind == .shell ? arguments?["command"]?.stringValue : nil,
      status: .running, output: "")
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
}
