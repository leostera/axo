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

  /// Stable across reloads: the record that made it.
  public let id: String
  public let role: Role
  public let text: String
  /// Prose roles, parsed once here and not each time the screen redraws.
  public let blocks: [MarkdownBlock]
  /// When it happened, in milliseconds since 1970, as Pi recorded it.
  public let timestamp: Int64?
  public fileprivate(set) var tool: ToolActivity?
  public var images: [ChatImage] = []
  /// A reply's pieces, by when Pi wrote it and their place in it: the same while the reply is
  /// written and once it is recorded, so the conversation carries it from one to the other.
  public var replyKey: String?

  /// Who this message is to the conversation on screen: the reply it is part of, or its record.
  public var key: String { replyKey ?? id }

  static func replyKey(timestamp: Int64?, index: Int) -> String? {
    timestamp.map { "reply:\($0)#\(index)" }
  }
}

/// A conversation as the host's records tell it (RFD0018). The records are the lines of the
/// agent's transcript, read by `entry(of:)`, the one place that knows the format. Whole messages
/// make the conversation; progress slots show the reply being written, a running tool's output and
/// a question, until a record says what came of them. A record already held is never applied
/// twice. A tool's result is not a message of its own: it fills in the tool that asked.
public struct ChatTranscript: Equatable, Sendable {
  public enum Activity: Equatable, Sendable {
    case idle
    case working
  }

  public private(set) var messages: [ChatMessage] = []
  /// Whether the agent is working, as the host last said.
  public private(set) var activity: Activity = .idle
  /// The reply the agent is writing, as far as it has got; gone once the reply is whole.
  public private(set) var live: [ChatMessage] = []
  /// What the agent is waiting for the person to answer.
  public private(set) var question: ChatQuestion?
  /// The records held, oldest first, without gaps.
  public private(set) var records: [ClientRecord] = []
  private var results: [String: ToolResult] = [:]
  /// When each recorded reply was started, as Pi stamps it. A reply's progress carries the same
  /// stamp, so a snapshot that arrives after its record (or is replayed on reopening) is known and
  /// not shown a second time below it.
  private var recordedReplies: Set<Int64> = []
  /// Running tools' output so far, by call id.
  private var toolOutput: [String: String] = [:]
  /// The clients' prompts whose user message the log holds, by commandId (RFD0024).
  public private(set) var delivered: Set<String> = []
  /// The entry id of the newest user message: the turn a stop names while the agent works.
  public private(set) var lastUserEntry: String?
  /// A receipt whose user message has not been read yet.
  private var receipt: String?

  /// The custom entry the Session's Pi writes just before a client's prompt: its commandId.
  static let receiptEntry = "axo.command"

  public init() {}

  /// A conversation read from records, oldest first. Parsing is the expensive part (every
  /// message's Markdown), so a page is made away from the main actor and then joined to what is
  /// shown with `prepend(older:)`.
  public init(records: [ClientRecord]) {
    append(records)
  }

  /// The first cursor held, or nil when none is.
  public var firstCursor: Int64? { records.first?.cursor }
  /// The last cursor held: what the next record follows.
  public var lastCursor: Int64 { records.last?.cursor ?? 0 }

  /// Records after the last held; any already held are skipped.
  public mutating func append(_ new: [ClientRecord]) {
    for record in new where record.cursor > lastCursor {
      records.append(record)
      apply(record)
    }
  }

  /// Puts an older page, parsed apart, before everything shown. Only the page's own messages are
  /// touched (its tools may be answered by results already shown), not the whole conversation.
  public mutating func prepend(older page: ChatTranscript) {
    let first = firstCursor ?? .max
    guard page.lastCursor < first, !page.records.isEmpty else { return }
    var older = page.messages
    for index in older.indices {
      if let callID = older[index].tool?.callID, let result = results[callID] { older[index].tool?.fill(result) }
    }
    messages.insert(contentsOf: older, at: 0)
    records.insert(contentsOf: page.records, at: 0)
    results.merge(page.results) { newer, _ in newer }
    recordedReplies.formUnion(page.recordedReplies)
    delivered.formUnion(page.delivered)
    if lastUserEntry == nil { lastUserEntry = page.lastUserEntry }
  }

  /// The host's copy was cut back: everything after `keep` goes.
  public mutating func cut(keep: Int64) {
    guard lastCursor > keep else { return }
    let kept = records.filter { $0.cursor <= keep }
    messages = []
    records = []
    results = [:]
    recordedReplies = []
    delivered = []
    lastUserEntry = nil
    receipt = nil
    append(kept)
  }

  /// A progress slot's newest snapshot, or null to clear it: `"message"` is the reply being
  /// written, `"question"` what the agent asks, any other slot a running tool's call id.
  public mutating func progress(slot: String, snapshot: JSONValue) {
    switch slot {
    case "message":
      guard let message = snapshot["message"], message["role"]?.stringValue == "assistant",
        Self.timestamp(of: message).map(recordedReplies.contains) != true
      else {
        live = []
        return
      }
      let timestamp = Self.timestamp(of: message)
      live = Self.pieces(of: message, role: "assistant").enumerated().map { index, piece in
        ChatMessage(
          id: "live#\(index)", role: piece.role, text: piece.text,
          // Parsed as it grows: a reply is short enough that this keeps up.
          blocks: piece.role == .assistant || piece.role == .thinking ? MarkdownBlocks.parse(piece.text) : [],
          timestamp: nil, tool: piece.tool, images: piece.images,
          replyKey: ChatMessage.replyKey(timestamp: timestamp, index: index))
      }
    case "question":
      guard snapshot != .null else {
        question = nil
        return
      }
      let kind = snapshot["kind"]?.stringValue.flatMap(ChatQuestion.Kind.init(rawValue:)) ?? .custom
      question = ChatQuestion(kind: kind, title: snapshot["title"]?.stringValue)
    default:
      guard snapshot != .null else {
        toolOutput[slot] = nil
        return
      }
      let output = Self.visibleText(snapshot["partialResult"]?["content"])
      toolOutput[slot] = output
      if let index = messages.firstIndex(where: { $0.tool?.callID == slot }), messages[index].tool?.status == .running {
        messages[index].tool?.output = output
      }
    }
  }

  /// Whether the agent is working, as the host says. Going idle also ends a reply and a question
  /// left open.
  public mutating func settle(working: Bool) {
    activity = working ? .working : .idle
    if !working {
      live = []
      question = nil
    }
  }

  private mutating func apply(_ record: ClientRecord) {
    let entry = Self.entry(of: record)
    if case .receipt(let commandId) = entry {
      receipt = commandId
      return
    }
    guard case .message(let id, let message) = entry, let role = message["role"]?.stringValue else {
      return
    }
    // The person's message sent by a client: keyed as its pending row was (see `PendingPrompt.key`).
    let promptKey = role == "user" ? receipt.map { HostWorkbenchModel.PendingPrompt.key(commandId: $0) } : nil
    if role == "user" {
      lastUserEntry = id
      if let receipt { delivered.insert(receipt) }
      receipt = nil
    }
    if role == "toolResult" {
      recordResult(of: message)
      return
    }
    let timestamp = Self.timestamp(of: message)
    if role == "assistant" {
      live = []
      if let timestamp { recordedReplies.insert(timestamp) }
    }
    for (index, piece) in Self.pieces(of: message, role: role).enumerated() {
      var tool = piece.tool
      if let callID = tool?.callID {
        if let result = results[callID] { tool?.fill(result) } else if let output = toolOutput[callID] { tool?.output = output }
      }
      messages.append(
        ChatMessage(
          id: index == 0 ? id : "\(id)#\(index)", role: piece.role, text: piece.text,
          blocks: piece.role == .assistant || piece.role == .thinking ? MarkdownBlocks.parse(piece.text) : [],
          timestamp: timestamp, tool: tool, images: piece.images,
          replyKey: role == "assistant"
            ? ChatMessage.replyKey(timestamp: timestamp, index: index) : index == 0 ? promptKey : promptKey.map { "\($0)#\(index)" }))
    }
  }

  /// When Pi started the message, in milliseconds since 1970.
  private static func timestamp(of message: JSONValue) -> Int64? {
    message["timestamp"]?.numberValue.map { Int64($0) }
  }

  /// A record as the conversation sees it: a message, a client's receipt, or nothing to show.
  private enum Entry {
    case message(id: String, JSONValue)
    case receipt(commandId: String)
    case other
  }

  /// The format adapter for `pi/3`: Pi's session file entries.
  private static func entry(of record: ClientRecord) -> Entry {
    guard record.format == "pi/3", let value = try? JSONDecoder().decode(JSONValue.self, from: Data(record.line.utf8))
    else { return .other }
    if value["type"]?.stringValue == "custom", value["customType"]?.stringValue == receiptEntry {
      guard let commandId = value["data"]?["commandId"]?.stringValue else { return .other }
      return .receipt(commandId: commandId)
    }
    guard value["type"]?.stringValue == "message", let message = value["message"], case .object = message
    else { return .other }
    return .message(id: value["id"]?.stringValue ?? "#\(record.cursor)", message)
  }

  private mutating func recordResult(of message: JSONValue) {
    guard let callID = message["toolCallId"]?.stringValue else { return }
    let status: ToolActivity.Status = message["isError"]?.boolValue == true ? .failed : .completed
    let result = ToolResult(
      status: status, output: Self.visibleText(message["content"]),
      truncated: message["truncated"]?.boolValue == true)
    results[callID] = result
    toolOutput[callID] = nil
    if let index = messages.firstIndex(where: { $0.tool?.callID == callID }) {
      messages[index].tool?.fill(result)
    }
  }

  private struct Piece {
    let role: ChatMessage.Role
    let text: String
    var tool: ToolActivity?
    var images: [ChatImage] = []
  }

  /// What the person said, with the lines pi-axo adds for a prompt's attachments (RFD0030) made
  /// short: an image's goes (the image shows itself), a file's becomes "📎 name".
  public static func attachmentsShown(_ text: String) -> String {
    guard text.contains("axo-asset:sha256:") else { return text }
    let image = /^\[Attached image: .+ at .+ axo-asset:sha256:[0-9a-f]{64}\]$/
    let file = /^\[Attached file: (.+) \([^,()]+, [^()]+\) at .+ axo-asset:sha256:[0-9a-f]{64}\]$/
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
      if line.wholeMatch(of: image) != nil { return nil }
      if let match = line.wholeMatch(of: file) { return "📎 \(match.1)" }
      return String(line)
    }
    // The blank lines between what was taken out fold into one.
    return lines.enumerated().filter { index, line in !(line.isEmpty && index > 0 && lines[index - 1].isEmpty) }
    .map(\.element)
    .joined(separator: "\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func pieces(of message: JSONValue, role: String) -> [Piece] {
    let content = message["content"]
    switch role {
    case "user":
      let text = attachmentsShown(visibleText(content))
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
