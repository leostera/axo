import AppKit
import GhosttyKit
import CoreText

/// Context menu, Services and bounded accessibility of the visible viewport.
extension GhosttySurfaceNSView {
  override func menu(for event: NSEvent) -> NSMenu? {
    guard let surface else { return nil }
    switch event.type {
    case .rightMouseDown:
      break
    case .leftMouseDown:
      guard event.modifierFlags.contains(.control), !ghostty_surface_mouse_captured(surface) else {
        return nil
      }
      sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    default:
      return nil
    }

    window?.makeFirstResponder(self)
    onFocus?()
    let menu = NSMenu()
    menu.autoenablesItems = false
    for item in TerminalContextMenuPolicy.items(
      hasSelection: ghostty_surface_has_selection(surface))
    {
      let title: String
      let action: Selector
      switch item {
      case .copy:
        title = "Copy"
        action = #selector(copy(_:))
      case .paste:
        title = "Paste"
        action = #selector(paste(_:))
      case .separator:
        menu.addItem(.separator())
        continue
      case .splitRight:
        title = "Split Right"
        action = #selector(splitRight(_:))
      case .splitDown:
        title = "Split Down"
        action = #selector(splitDown(_:))
      case .closePane:
        title = "Close Pane"
        action = #selector(closePane(_:))
      }
      menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }
    return menu
  }

  override func isAccessibilityElement() -> Bool { true }

  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

  override func accessibilityLabel() -> String? { "Terminal" }

  override func accessibilityHelp() -> String? {
    "Terminal content area. Only visible screen text is exposed."
  }

  override func accessibilityValue() -> Any? { accessibilityVisibleText() }

  override func accessibilitySelectedTextRange() -> NSRange {
    TerminalAccessibilitySnapshot.selectedRange(
      selectedRange(), visibleText: accessibilityVisibleText())
  }

  override func accessibilitySelectedText() -> String? {
    let visibleText = accessibilityVisibleText()
    let range = TerminalAccessibilitySnapshot.selectedRange(selectedRange(), visibleText: visibleText)
    guard range.location != NSNotFound, range.length > 0 else { return nil }
    return TerminalAccessibilitySnapshot.string(visibleText, in: range)
  }

  override func accessibilityNumberOfCharacters() -> Int {
    (accessibilityVisibleText() as NSString).length
  }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: accessibilityNumberOfCharacters())
  }

  override func accessibilityLine(for index: Int) -> Int {
    TerminalAccessibilitySnapshot.line(for: index, in: accessibilityVisibleText())
  }

  override func accessibilityString(for range: NSRange) -> String? {
    TerminalAccessibilitySnapshot.string(accessibilityVisibleText(), in: range)
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    guard let surface, let value = accessibilityString(for: range) else { return nil }
    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }
    return NSAttributedString(string: value, attributes: attributes)
  }

  override func validRequestor(
    forSendType sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Any? {
    guard let surface,
      TerminalServicesPolicy.canServe(
        sendType: sendType,
        returnType: returnType,
        hasSelection: ghostty_surface_has_selection(surface))
    else {
      return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    return self
  }

  func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard !types.isEmpty, types.allSatisfy(TerminalServicesPolicy.textTypes.contains),
      let surface
    else { return false }
    var selection = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selection) else { return false }
    defer { ghostty_surface_free_text(surface, &selection) }
    guard let text = selection.text else { return false }
    let value = String(decoding: Data(bytes: text, count: Int(selection.text_len)), as: UTF8.self)
    pasteboard.declareTypes([.string], owner: nil)
    return pasteboard.setString(value, forType: .string)
  }

  func readSelection(from pasteboard: NSPasteboard) -> Bool {
    guard let text = TerminalServicesPolicy.textTypes.lazy.compactMap({
      pasteboard.string(forType: $0)
    }).first else { return false }
    return runtime?.pasteText(text, into: shellID) ?? false
  }

  func accessibilityVisibleText() -> String {
    guard let surface else { return "" }
    var visible = ghostty_text_s()
    let viewport = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0,
        y: 0),
      bottom_right: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0,
        y: 0),
      rectangle: false)
    guard ghostty_surface_read_text(surface, viewport, &visible) else { return "" }
    defer { ghostty_surface_free_text(surface, &visible) }
    guard let pointer = visible.text else { return "" }
    let byteCount = min(Int(visible.text_len), TerminalAccessibilitySnapshot.maximumUTF8Bytes)
    let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: byteCount)
    return TerminalAccessibilitySnapshot.bounded(String(decoding: bytes, as: UTF8.self))
  }
}
