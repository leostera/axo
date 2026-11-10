import Foundation

/// Where a tool's row sits among the tools the agent used one after another, with nothing said in
/// between: they show as one block, headed by what they did together. As on the web.
public struct ToolGroupPlace: Equatable, Sendable {
  public let first: Bool
  public let last: Bool
  /// On the first row of a block of two or more: what the block did, as "Read 3 files, ran a command".
  public let title: String?

  public init(first: Bool, last: Bool, title: String?) {
    self.first = first
    self.last = last
    self.title = title
  }

  /// Each row's place in its block, for rows given by their tool (nil for a row that is not a tool's).
  public static func places(_ tools: [ToolActivity?]) -> [ToolGroupPlace?] {
    var places = [ToolGroupPlace?](repeating: nil, count: tools.count)
    var start = 0
    while start < tools.count {
      guard tools[start] != nil else {
        start += 1
        continue
      }
      var end = start
      while end + 1 < tools.count, tools[end + 1] != nil { end += 1 }
      let block = tools[start...end].compactMap { $0 }
      let title = block.count > 1 ? Self.title(of: block) : nil
      for index in start...end {
        places[index] = ToolGroupPlace(first: index == start, last: index == end, title: index == start ? title : nil)
      }
      start = end + 1
    }
    return places
  }

  /// What a block of tools did, in the order it first did each thing: "Read 3 files, edited 2 files, ran 4 commands".
  public static func title(of tools: [ToolActivity]) -> String {
    struct Action {
      let verb: String
      let one: String
      let many: String
      var things: Set<String> = []
      var count = 0
    }
    var order: [String] = []
    var actions: [String: Action] = [:]
    for tool in tools {
      let (verb, one, many) = action(tool)
      let key = "\(verb) \(one) \(many)"
      var entry = actions[key] ?? Action(verb: verb, one: one, many: many)
      entry.count += 1
      // A file edited twice is one file edited.
      if many == "files", let path = tool.subtitle?.components(separatedBy: " · ").first { entry.things.insert(path) }
      if actions[key] == nil { order.append(key) }
      actions[key] = entry
    }
    let sentence = order.compactMap { actions[$0] }.map { action -> String in
      let n = action.things.isEmpty ? action.count : action.things.count
      if n == 1 { return "\(action.verb) \(action.one)" }
      // "used mcp 3 times": a tool with no better words is counted after its name.
      return action.many.isEmpty ? "\(action.verb) \(action.one) \(n) times" : "\(action.verb) \(n) \(action.many)"
    }.joined(separator: ", ")
    return sentence.prefix(1).uppercased() + sentence.dropFirst()
  }

  /// How a tool's work reads: its verb, and what it acts on, one and many.
  private static func action(_ tool: ToolActivity) -> (String, String, String) {
    switch tool.name {
    case "bash": ("ran", "a command", "commands")
    case "edit": ("edited", "a file", "files")
    case "write": ("wrote", "a file", "files")
    case "read": ("read", "a file", "files")
    case "codemode", "mcpScript": ("ran", "a script", "scripts")
    case "grep", "find", "ls", "search": ("searched", "once", "times")
    default: ("used", tool.name, "")
    }
  }
}

extension ToolActivity {
  /// The tool's input in a line, for its row: the path it works on, or the first line it was given.
  public var preview: String {
    if let subtitle, !subtitle.isEmpty { return subtitle }
    let text = command ?? (input?.kind == .arguments ? nil : input?.text) ?? ""
    return text.components(separatedBy: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty && !$0.hasPrefix("//") } ?? ""
  }
}
