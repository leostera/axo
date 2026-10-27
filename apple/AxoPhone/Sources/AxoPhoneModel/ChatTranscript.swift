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
  /// The output was cut short to cross the wire; the Mac has all of it.
  public fileprivate(set) var outputTruncated = false

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
    outputTruncated = result.truncated
  }
}

/// How a tool call ended, as its result message says.
private struct ToolResult: Equatable, Sendable {
  let status: ToolActivity.Status
  let output: String
  var truncated = false
}

/// A picture in a message, as Pi recorded it.
public struct ChatImage: Equatable, Sendable, Identifiable {
  public let id: Int
  public let data: Data
  public let mimeType: String?
}

/// What Pi is asking the person, while it waits for an answer.
public struct ChatQuestion: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    /// Yes or no.
    case confirm
    /// A line of text.
    case input
    /// One of several choices; the choices are only shown on the Mac.
    case select
    /// A longer text, or a screen of the extension's own; answered on the Mac.
    case editor, custom
  }

  public let kind: Kind
  public let title: String?
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
  /// Prose roles, parsed once here and not each time the screen redraws.
  public let blocks: [MarkdownBlock]
  /// When it happened, in milliseconds since 1970, as Pi recorded it.
  public let timestamp: Int64?
  public fileprivate(set) var tool: ToolActivity?
  public var images: [ChatImage] = []
}

/// A conversation as Pi's events tell it. Whole messages (`message.end`) make the conversation;
/// the reply being written (`message.update`) and a running tool's output (`tool.update`) show
/// as they grow; the rest of the stream says whether Pi is working or asking something.
/// Replaying an event, or reading history that overlaps what already arrived live, never repeats
/// a message. A tool's result is not a message of its own: it fills in the tool that asked.
public struct ChatTranscript: Equatable, Sendable {
  public enum Activity: Equatable, Sendable {
    case idle
    case working
  }

  public private(set) var messages: [ChatMessage] = []
  public private(set) var activity: Activity = .idle
  /// The reply Pi is writing, as far as it has got; gone once the reply is whole.
  public private(set) var live: [ChatMessage] = []
  /// What Pi is waiting for the person to answer.
  public private(set) var question: ChatQuestion?
  private var known: Set<String> = []
  private var results: [String: ToolResult] = [:]

  public init() {}

  public mutating func apply(_ record: PiEventRecord) {
    switch record.name {
    case "agent.start": activity = .working
    case "agent.end", "agent.settled":
      activity = .idle
      live = []
    case "activity.snapshot":
      if let working = record.data["working"]?.boolValue { activity = working ? .working : .idle }
    case "ui.prompt.start":
      let kind = record.data["kind"]?.stringValue.flatMap(ChatQuestion.Kind.init(rawValue:)) ?? .custom
      question = ChatQuestion(kind: kind, title: record.data["title"]?.stringValue)
    case "ui.prompt.end":
      question = nil
    case "message.update":
      guard let message = record.data["message"], message["role"]?.stringValue == "assistant" else { return }
      live = Self.pieces(of: message, role: "assistant").enumerated().map { index, piece in
        ChatMessage(
          id: "live#\(index)", role: piece.role, text: piece.text,
          // Parsed as it grows: a reply is short enough that this keeps up.
          blocks: piece.role == .assistant || piece.role == .thinking ? MarkdownBlocks.parse(piece.text) : [],
          timestamp: nil, tool: piece.tool, images: piece.images)
      }
    case "tool.update":
      guard let callID = record.data["toolCallId"]?.stringValue,
        let index = messages.firstIndex(where: { $0.tool?.callID == callID }),
        messages[index].tool?.status == .running
      else { return }
      messages[index].tool?.output = Self.visibleText(record.data["partialResult"]?["content"])
    case "message.end":
      let id = Self.id(of: record)
      guard !known.contains(id) else { return }
      guard let message = record.data["message"], let role = message["role"]?.stringValue else { return }
      if role == "toolResult" {
        recordResult(of: message)
        return
      }
      if role == "assistant" { live = [] }
      let timestamp = message["timestamp"]?.numberValue.map { Int64($0) }
      for (index, piece) in Self.pieces(of: message, role: role).enumerated() {
        known.insert(id)
        var tool = piece.tool
        if let callID = tool?.callID, let result = results[callID] { tool?.fill(result) }
        messages.append(
          ChatMessage(
            id: index == 0 ? id : "\(id)#\(index)", role: piece.role, text: piece.text,
            blocks: piece.role == .assistant || piece.role == .thinking ? MarkdownBlocks.parse(piece.text) : [],
            timestamp: timestamp, tool: tool, images: piece.images))
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

  /// What the Mac last said about whether Pi is working, for when the live events were missed
  /// (the phone was asleep or offline). Going idle also ends a reply and a question left open.
  public mutating func settle(working: Bool) {
    activity = working ? .working : .idle
    if !working {
      live = []
      question = nil
    }
  }

  private mutating func recordResult(of message: JSONValue) {
    guard let callID = message["toolCallId"]?.stringValue else { return }
    let status: ToolActivity.Status = message["isError"]?.boolValue == true ? .failed : .completed
    let result = ToolResult(
      status: status, output: Self.visibleText(message["content"]),
      truncated: message["truncated"]?.boolValue == true)
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
    var images: [ChatImage] = []
  }

  private static func pieces(of message: JSONValue, role: String) -> [Piece] {
    let content = message["content"]
    switch role {
    case "user":
      let text = visibleText(content)
      let images = Self.images(in: content)
      return text.isEmpty && images.isEmpty ? [] : [Piece(role: .user, text: text, tool: nil, images: images)]
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
    var images: [ChatImage] = []
    func flushWords() {
      let text = words.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty || !images.isEmpty { pieces.append(Piece(role: .assistant, text: text, tool: nil, images: images)) }
      words = []
      images = []
    }
    for block in content?.arrayValue ?? [] {
      switch block["type"]?.stringValue {
      case "text":
        if let text = block["text"]?.stringValue { words.append(text) }
      case "image":
        if let image = Self.image(block, index: images.count) { images.append(image) } else { words.append("[Image attachment]") }
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

  /// The words of a message. A picture that came with its data is shown as itself (`images`);
  /// one without (cut to cross the wire) is named.
  private static func visibleText(_ content: JSONValue?) -> String {
    if let text = content?.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    return (content?.arrayValue ?? []).compactMap { block -> String? in
      switch block["type"]?.stringValue {
      case "text": block["text"]?.stringValue
      case "image": image(block, index: 0) == nil ? "[Image attachment]" : nil
      default: nil
      }
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func images(in content: JSONValue?) -> [ChatImage] {
    (content?.arrayValue ?? []).filter { $0["type"]?.stringValue == "image" }.enumerated()
      .compactMap { index, block in image(block, index: index) }
  }

  private static func image(_ block: JSONValue, index: Int) -> ChatImage? {
    guard let encoded = block["data"]?.stringValue, let data = Data(base64Encoded: encoded), !data.isEmpty else {
      return nil
    }
    return ChatImage(id: index, data: data, mimeType: block["mimeType"]?.stringValue)
  }
}
