import AppKit
import Foundation

/// Ghostty binding actions used by Ghostty.app's find UI, built in one place so the Axo find bar
/// sends exactly the same commands.
enum TerminalFindAction: Equatable {
  case start, selection, end, next, previous
  case search(String)

  var bindingAction: String {
    switch self {
    case .start: "start_search"
    case .selection: "search_selection"
    case .end: "end_search"
    case .next: "navigate_search:next"
    case .previous: "navigate_search:previous"
    case .search(let needle): "search:\(needle)"
    }
  }

  /// "2 of 5", "5 matches", or nothing before Ghostty reports a total.
  static func countLabel(_ search: TerminalSurfaceStatus.Search?) -> String {
    guard let total = search?.total else { return "" }
    if let selected = search?.selected, total > 0 { return "\(selected + 1) of \(total)" }
    return total == 1 ? "1 match" : "\(total) matches"
  }
}

/// Axo-owned find bar shown at the top of a pane while Ghostty reports an active search.
/// Return/Shift-Return navigate, Escape ends the search and returns focus to the terminal.
final class TerminalFindBarView: NSView, NSSearchFieldDelegate {
  let field = NSSearchField()
  private let count = NSTextField(labelWithString: "")
  var onAction: ((TerminalFindAction) -> Void)?
  private var lastSentNeedle: String?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    layer?.cornerRadius = 6
    field.placeholderString = "Find"
    field.delegate = self
    field.sendsSearchStringImmediately = true
    field.setAccessibilityIdentifier("terminal-find-field")
    count.textColor = .secondaryLabelColor
    count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    count.setAccessibilityIdentifier("terminal-find-count")
    addSubview(field)
    addSubview(count)
    isHidden = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for TerminalFindBarView")
  }

  override func layout() {
    super.layout()
    let countWidth: CGFloat = 72
    field.frame = NSRect(x: 6, y: 4, width: bounds.width - countWidth - 12, height: bounds.height - 8)
    count.frame = NSRect(x: bounds.width - countWidth - 4, y: 6, width: countWidth, height: 16)
  }

  func show(_ search: TerminalSurfaceStatus.Search?, in bounds: NSRect) {
    guard let search else {
      if !isHidden, window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(nil) }
      isHidden = true
      lastSentNeedle = nil
      return
    }
    let width = min(320, max(bounds.width - 16, 0))
    frame = NSRect(x: bounds.maxX - width - 8, y: bounds.maxY - 36, width: width, height: 30)
    if field.stringValue != search.needle, field.currentEditor() == nil {
      field.stringValue = search.needle
      lastSentNeedle = search.needle
    }
    count.stringValue = TerminalFindAction.countLabel(search)
    let wasHidden = isHidden
    isHidden = false
    if wasHidden { window?.makeFirstResponder(field) }
  }

  func controlTextDidChange(_ obj: Notification) {
    let needle = field.stringValue
    guard needle != lastSentNeedle else { return }
    lastSentNeedle = needle
    onAction?(.search(needle))
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      onAction?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .previous : .next)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onAction?(.end)
      return true
    default:
      return false
    }
  }
}
