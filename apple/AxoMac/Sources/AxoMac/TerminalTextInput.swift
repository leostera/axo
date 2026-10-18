import AppKit
import Foundation

struct TerminalCommittedText {
  private var pendingLeadSurrogate: UInt16?

  mutating func decode(_ input: Any) -> String? {
    if let attributedText = input as? NSAttributedString {
      pendingLeadSurrogate = nil
      return attributedText.string
    }

    if Swift.type(of: input) == String.self, let text = input as? String {
      pendingLeadSurrogate = nil
      return text
    }

    guard let text = input as? NSString else { return nil }
    return decodeUTF16(text)
  }

  private mutating func decodeUTF16(_ text: NSString) -> String? {
    guard text.length == 1 else {
      pendingLeadSurrogate = nil
      return text as String
    }

    let codeUnit = text.character(at: 0)
    if (0xD800...0xDBFF).contains(codeUnit) {
      pendingLeadSurrogate = codeUnit
      return ""
    }

    if (0xDC00...0xDFFF).contains(codeUnit) {
      guard let lead = pendingLeadSurrogate else { return nil }
      pendingLeadSurrogate = nil
      let scalarValue = 0x10000 + (UInt32(lead - 0xD800) << 10) + UInt32(codeUnit - 0xDC00)
      guard let scalar = UnicodeScalar(scalarValue) else { return nil }
      return String(scalar)
    }

    pendingLeadSurrogate = nil
    return text as String
  }
}

struct TerminalIMEGeometry {
  static func viewRect(
    requestedRange: NSRange,
    selectionRange: NSRange,
    selectionTopLeft: CGPoint?,
    imePoint: CGRect,
    cellSize: CGSize,
    viewSize: CGSize
  ) -> CGRect {
    var x = imePoint.minX
    var y = imePoint.minY
    var width = imePoint.width > 0 ? imePoint.width : cellSize.width
    let height = imePoint.height > 0 ? imePoint.height : cellSize.height

    if requestedRange.length > 0, requestedRange != selectionRange,
      let selectionTopLeft
    {
      x = selectionTopLeft.x - 2
      y = selectionTopLeft.y + 2
    }

    if requestedRange.length == 0, width > 0 {
      width = 0
      x += cellSize.width * CGFloat(requestedRange.location)
    }

    return CGRect(
      x: x,
      y: viewSize.height - y,
      width: width,
      height: max(height, cellSize.height)
    )
  }
}
