import Foundation

struct TerminalAccessibilitySnapshot {
  static let maximumUTF8Bytes = 64 * 1024

  static func bounded(_ text: String, maximumBytes: Int = maximumUTF8Bytes) -> String {
    var result = ""
    var byteCount = 0
    for scalar in text.unicodeScalars {
      let scalarByteCount = scalar.utf8.count
      guard byteCount + scalarByteCount <= maximumBytes else { break }
      result.unicodeScalars.append(scalar)
      byteCount += scalarByteCount
    }
    return result
  }

  static func string(_ text: String, in range: NSRange) -> String? {
    guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
    return String(text[swiftRange])
  }

  static func line(for characterIndex: Int, in text: String) -> Int {
    let nsText = text as NSString
    let safeIndex = min(max(characterIndex, 0), nsText.length)
    let prefix = nsText.substring(to: safeIndex)
    return prefix.reduce(into: 0) { line, character in
      if character == "\n" { line += 1 }
    }
  }

  static func selectedRange(_ range: NSRange, visibleText: String) -> NSRange {
    let length = (visibleText as NSString).length
    guard range.location != NSNotFound,
      range.location <= length,
      range.length <= length - range.location
    else { return NSRange(location: NSNotFound, length: 0) }
    return range
  }
}
