import Foundation

/// A terminal's output as readable text: what a phone shows until it has a real terminal view.
///
/// It understands only what is needed to read a shell: printable text, newlines, carriage
/// returns (a line rewritten from its start), backspace, and it drops escape sequences (colours,
/// cursor movement, window titles) instead of printing them. Full-screen programs will not look
/// right; that needs an emulator.
public struct PlainTerminalText: Equatable, Sendable {
  public static let defaultMaximumCharacters = 40_000

  public private(set) var lines: [String] = [""]
  private let maximumCharacters: Int
  private var escape = Escape.none
  /// UTF-8 bytes of a character split across two chunks.
  private var pendingBytes = Data()

  private enum Escape {
    case none
    /// After ESC, deciding which kind of sequence follows.
    case introduced
    /// ESC [ ... final byte in 0x40...0x7E.
    case controlSequence
    /// ESC ] ... ended by BEL or ESC \.
    case operatingSystemCommand
    case operatingSystemCommandEscape
  }

  public init(maximumCharacters: Int = defaultMaximumCharacters) {
    self.maximumCharacters = max(1, maximumCharacters)
  }

  /// The text as one string, lines joined by newlines.
  public var text: String { lines.joined(separator: "\n") }

  public mutating func append(_ output: Data) {
    var bytes = pendingBytes
    bytes.append(output)
    pendingBytes = Data()
    var index = bytes.startIndex
    while index < bytes.endIndex {
      let byte = bytes[index]
      if escape != .none {
        consumeEscape(byte)
        index = bytes.index(after: index)
        continue
      }
      if byte < 0x80 {
        write(ascii: byte)
        index = bytes.index(after: index)
        continue
      }
      let length = Self.utf8Length(of: byte)
      guard length > 0 else {
        write(character: "\u{FFFD}")
        index = bytes.index(after: index)
        continue
      }
      guard bytes.distance(from: index, to: bytes.endIndex) >= length else {
        pendingBytes = bytes[index...]
        return
      }
      let end = bytes.index(index, offsetBy: length)
      if let character = String(data: bytes[index..<end], encoding: .utf8)?.first {
        write(character: character)
        index = end
      } else {
        // Only the lead byte is wrong; what follows may be fine on its own.
        write(character: "\u{FFFD}")
        index = bytes.index(after: index)
      }
    }
    trim()
  }

  private static func utf8Length(of lead: UInt8) -> Int {
    switch lead {
    case 0xC2...0xDF: 2
    case 0xE0...0xEF: 3
    case 0xF0...0xF4: 4
    default: 0
    }
  }

  private mutating func consumeEscape(_ byte: UInt8) {
    switch escape {
    case .none:
      break
    case .introduced:
      switch byte {
      case UInt8(ascii: "["): escape = .controlSequence
      case UInt8(ascii: "]"): escape = .operatingSystemCommand
      // A two-byte sequence such as ESC = or ESC 7.
      default: escape = .none
      }
    case .controlSequence:
      if (0x40...0x7E).contains(byte) { escape = .none }
    case .operatingSystemCommand:
      if byte == 0x07 {
        escape = .none
      } else if byte == 0x1B {
        escape = .operatingSystemCommandEscape
      }
    case .operatingSystemCommandEscape:
      escape = byte == UInt8(ascii: "\\") ? .none : .operatingSystemCommand
    }
  }

  private mutating func write(ascii byte: UInt8) {
    switch byte {
    case 0x1B: escape = .introduced
    case 0x0A: newLine()
    case 0x0D: carriageReturn()
    case 0x08: backspace()
    case 0x09: write(character: "\t")
    case 0x20...0x7E: write(character: Character(UnicodeScalar(byte)))
    default: break  // bell and other control bytes have nothing to show
    }
  }

  private mutating func newLine() {
    lines.append("")
    column = 0
  }

  /// Where the next character lands in the current line; a carriage return moves it to 0.
  private var column = 0

  private mutating func carriageReturn() {
    column = 0
  }

  private mutating func backspace() {
    column = max(0, column - 1)
  }

  private mutating func write(character: Character) {
    var line = Array(lines[lines.count - 1])
    if column < line.count {
      line[column] = character
    } else {
      line.append(character)
    }
    column += 1
    lines[lines.count - 1] = String(line)
  }

  /// Drops the oldest lines once the text is longer than allowed.
  private mutating func trim() {
    var total = lines.reduce(0) { $0 + $1.count + 1 }
    while total > maximumCharacters, lines.count > 1 {
      total -= lines.removeFirst().count + 1
    }
  }
}
