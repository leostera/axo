import Foundation

/// The parts of a reply the phone draws differently: prose, headings, and code.
///
/// This is not a Markdown engine. It splits a reply where the look changes (fenced code, headings,
/// bullets), and leaves inline formatting (bold, links, `code`) to the text view. An unclosed
/// fence runs to the end, so a reply that is still arriving never loses its code.
public enum MarkdownBlock: Equatable, Sendable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case bullet(String)
  case code(language: String?, text: String)
}

public enum MarkdownBlocks {
  public static func parse(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var code: (language: String?, lines: [String])?

    func flushParagraph() {
      let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.paragraph(joined)) }
      paragraph = []
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if var open = code {
        if trimmed.hasPrefix("```") {
          blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
          code = nil
        } else {
          open.lines.append(line)
          code = open
        }
        continue
      }
      if trimmed.hasPrefix("```") {
        flushParagraph()
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        code = (language.isEmpty ? nil : language, [])
      } else if let heading = Self.heading(trimmed) {
        flushParagraph()
        blocks.append(heading)
      } else if let item = Self.bullet(trimmed) {
        flushParagraph()
        blocks.append(.bullet(item))
      } else if trimmed.isEmpty {
        flushParagraph()
      } else {
        paragraph.append(line)
      }
    }
    flushParagraph()
    if let open = code { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
    return blocks
  }

  private static func heading(_ line: String) -> MarkdownBlock? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : .heading(level: hashes, text: text)
  }

  private static func bullet(_ line: String) -> String? {
    for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
      let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : text
    }
    // "1. item"
    let digits = line.prefix { $0.isNumber }
    if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
      let text = line.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : text
    }
    return nil
  }
}
