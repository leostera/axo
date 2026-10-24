import AppKit
import GhosttyKit

/// `NSTextInputClient`: composition/preedit and committed text.
extension GhosttySurfaceNSView {
  func insertText(_ string: Any, replacementRange: NSRange) {
    guard NSApp.currentEvent != nil,
      let text = committedTextDecoder.decode(string)
    else { return }

    unmarkText()
    if committedText != nil {
      committedText?.append(text)
    } else if !text.isEmpty {
      sendCommittedText(GHOSTTY_ACTION_PRESS, text: text)
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    switch string {
    case let value as NSAttributedString:
      markedText = NSMutableAttributedString(attributedString: value)
    case let value as String:
      markedText = NSMutableAttributedString(string: value)
    default:
      return
    }
    if committedText == nil {
      syncPreedit(clearIfNeeded: true)
    }
  }

  func unmarkText() {
    guard hasMarkedText() else { return }
    clearMarkedText()
  }

  func hasMarkedText() -> Bool {
    markedText.length > 0
  }

  func markedRange() -> NSRange {
    markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
  }

  func selectedRange() -> NSRange {
    guard let surface else { return NSRange() }
    var selection = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selection) else { return NSRange() }
    defer { ghostty_surface_free_text(surface, &selection) }
    return NSRange(location: Int(selection.offset_start), length: Int(selection.offset_len))
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard let surface, range.length > 0 else { return nil }
    var selection = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selection) else { return nil }
    defer { ghostty_surface_free_text(surface, &selection) }

    let bytes = selection.text.map {
      Data(bytes: $0, count: Int(selection.text_len))
    } ?? Data()
    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }
    return NSAttributedString(
      string: String(decoding: bytes, as: UTF8.self), attributes: attributes)
  }

  func characterIndex(for point: NSPoint) -> Int {
    0
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else {
      return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
    }

    let size = ghostty_surface_size(surface)
    let selectionRange = selectedRange()
    let backingScale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
    let cellSize = CGSize(
      width: CGFloat(size.cell_width_px) / backingScale,
      height: CGFloat(size.cell_height_px) / backingScale
    )
    var x = 0.0
    var y = 0.0
    var width = Double(cellSize.width)
    var height = Double(cellSize.height)
    var selectionTopLeft: CGPoint?

    if range.length > 0, range != selectionRange {
      var selection = ghostty_text_s()
      if ghostty_surface_read_selection(surface, &selection) {
        selectionTopLeft = CGPoint(x: selection.tl_px_x, y: selection.tl_px_y)
        ghostty_surface_free_text(surface, &selection)
      } else {
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
      }
    } else {
      ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    }

    let viewRect = TerminalIMEGeometry.viewRect(
      requestedRange: range,
      selectionRange: selectionRange,
      selectionTopLeft: selectionTopLeft,
      imePoint: CGRect(x: x, y: y, width: width, height: height),
      cellSize: cellSize,
      viewSize: bounds.size
    )
    let windowRect = convert(viewRect, to: nil)
    guard let window else { return windowRect }
    return window.convertToScreen(windowRect)
  }

  func syncPreedit(clearIfNeeded: Bool) {
    guard let surface else { return }
    if hasMarkedText() {
      markedText.string.withCString {
        ghostty_surface_preedit(surface, $0, UInt(markedText.string.utf8.count))
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  func sendCommittedText(_ action: ghostty_input_action_e, text: String) {
    guard let surface else { return }
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = 0
    keyEvent.text = nil
    keyEvent.composing = false
    keyEvent.mods = GHOSTTY_MODS_NONE
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = 0
    text.withCString {
      keyEvent.text = $0
      _ = ghostty_surface_key(surface, keyEvent)
    }
  }

  func clearMarkedText() {
    markedText = NSMutableAttributedString()
    if let surface {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }
}
