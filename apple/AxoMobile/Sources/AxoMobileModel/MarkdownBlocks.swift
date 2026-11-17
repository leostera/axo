import Foundation

/// The parts of a reply the phone draws differently: prose, headings, lists, quotes, tables, rules
/// and code.
///
/// This is not a Markdown engine. It splits a reply where the look changes and leaves inline
/// formatting (bold, links, `code`) to `InlineText`. An unclosed fence runs to the end, so a
/// reply that is still arriving never loses its code.
public enum MarkdownBlock: Equatable, Sendable {
  case paragraph(InlineText)
  case heading(level: Int, text: InlineText)
  /// One list item. `depth` is 0 at the margin and grows with each level of indentation.
  case listItem(marker: ListMarker, depth: Int, text: InlineText)
  /// Consecutive `>` lines, without their markers.
  case quote(InlineText)
  /// A pipe table. Every row has as many cells as the header.
  case table(header: [InlineText], rows: [[InlineText]])
  case rule
  case code(language: String?, text: String)
}

/// A line of prose with its inline formatting (bold, italics, links, `code`) read once, when the
/// message is parsed, rather than each time the screen draws it: a row coming into view while
/// the conversation scrolls has no Markdown left to read.
public struct InlineText: Equatable, Sendable, ExpressibleByStringLiteral {
  /// As written.
  public let source: String
  /// As shown.
  public let styled: AttributedString

  public init(_ source: String) {
    self.source = source
    styled = (try? AttributedString(
      markdown: source,
      options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(source)
  }

  public init(stringLiteral value: String) { self.init(value) }

  /// The same words are the same text; the styling follows from them.
  public static func == (lhs: InlineText, rhs: InlineText) -> Bool { lhs.source == rhs.source }
}

public enum ListMarker: Equatable, Sendable {
  case bullet
  /// "3." keeps its number, as written.
  case number(Int)
}

public enum MarkdownBlocks {
  public static func parse(_ text: String) -> [MarkdownBlock] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var quote: [String] = []

    func flushParagraph() {
      let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.paragraph(InlineText(joined))) }
      paragraph = []
    }
    func flushQuote() {
      let joined = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.quote(InlineText(joined))) }
      quote = []
    }
    func flush() {
      flushParagraph()
      flushQuote()
    }

    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      index += 1

      if trimmed.hasPrefix("```") {
        flush()
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        var code: [String] = []
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          code.append(lines[index])
          index += 1
        }
        index += 1  // the closing fence, if there is one
        blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
      } else if let quoted = Self.quoted(trimmed) {
        flushParagraph()
        quote.append(quoted)
      } else if trimmed.isEmpty {
        flush()
      } else if Self.isRule(trimmed) {
        flush()
        blocks.append(.rule)
      } else if let heading = Self.heading(trimmed) {
        flush()
        blocks.append(heading)
      } else if let item = Self.listItem(line) {
        flush()
        blocks.append(item)
      } else if let header = Self.cells(trimmed), index < lines.count,
        Self.isTableSeparator(lines[index].trimmingCharacters(in: .whitespaces), columns: header.count)
      {
        flush()
        index += 1
        var rows: [[String]] = []
        while index < lines.count, let row = Self.cells(lines[index].trimmingCharacters(in: .whitespaces), minimum: 1) {
          rows.append(Self.fit(row, to: header.count))
          index += 1
        }
        let styled: ([String]) -> [InlineText] = { $0.map { InlineText($0) } }
        blocks.append(.table(header: styled(header), rows: rows.map(styled)))
      } else {
        flushQuote()
        paragraph.append(line)
      }
    }
    flush()
    return blocks
  }

  private static func heading(_ line: String) -> MarkdownBlock? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : .heading(level: hashes, text: InlineText(text))
  }

  /// A list item, with its depth from the indentation: two spaces (or a tab) per level.
  private static func listItem(_ line: String) -> MarkdownBlock? {
    let indent = line.prefix { $0 == " " || $0 == "\t" }
    let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    let depth = min(width / 2, 6)
    let rest = line.dropFirst(indent.count)
    for marker in ["- ", "* ", "+ ", "• "] where rest.hasPrefix(marker) {
      let text = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : .listItem(marker: .bullet, depth: depth, text: InlineText(text))
    }
    let digits = rest.prefix { $0.isNumber }
    if !digits.isEmpty, digits.count <= 9, let number = Int(digits),
      rest.dropFirst(digits.count).hasPrefix(". ") || rest.dropFirst(digits.count).hasPrefix(") ")
    {
      let text = rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : .listItem(marker: .number(number), depth: depth, text: InlineText(text))
    }
    return nil
  }

  private static func quoted(_ line: String) -> String? {
    guard line.hasPrefix(">") else { return nil }
    let rest = line.dropFirst()
    return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
  }

  /// `---`, `***` or `___`, three or more, spaces allowed between.
  private static func isRule(_ line: String) -> Bool {
    let marks = line.filter { $0 != " " }
    guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
    return marks.allSatisfy { $0 == first }
  }

  /// A table row's cells, if the line is one: it has a pipe, and the outer pipes are optional.
  /// A header needs two cells to be told from prose; a row under one may have fewer.
  private static func cells(_ line: String, minimum: Int = 2) -> [String]? {
    guard line.contains("|") else { return nil }
    var body = Substring(line)
    if body.hasPrefix("|") { body = body.dropFirst() }
    if body.hasSuffix("|") { body = body.dropLast() }
    let cells = body.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    return cells.count >= minimum ? cells : nil
  }

  /// `|---|:--:|` under a header with `columns` cells.
  private static func isTableSeparator(_ line: String, columns: Int) -> Bool {
    guard let cells = cells(line), cells.count == columns else { return false }
    return cells.allSatisfy { cell in
      let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
    }
  }

  private static func fit(_ row: [String], to columns: Int) -> [String] {
    row.count >= columns ? Array(row.prefix(columns)) : row + Array(repeating: "", count: columns - row.count)
  }
}
