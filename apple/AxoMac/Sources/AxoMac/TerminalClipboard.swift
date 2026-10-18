import AppKit
import Foundation
import GhosttyKit

struct TerminalClipboardContent {
  let mimeType: String
  let data: Data

  var text: String? {
    guard mimeType == TerminalClipboardPolicy.textMIMEType else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

enum TerminalClipboardPolicy {
  static let textMIMEType = "text/plain"
  static let selectionPasteboardName = "dev.leostera.axo.selection"

  static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
    switch location {
    case GHOSTTY_CLIPBOARD_STANDARD:
      NSPasteboard.general
    case GHOSTTY_CLIPBOARD_SELECTION:
      NSPasteboard(name: .init(selectionPasteboardName))
    default:
      nil
    }
  }

  static func singlePlainText(from contents: [TerminalClipboardContent]) -> String? {
    guard contents.count == 1,
      let content = contents.first,
      content.mimeType == textMIMEType
    else { return nil }
    return content.text
  }

  static func availableMIMETypes(hasPlainText: Bool) -> [String] {
    hasPlainText ? [textMIMEType] : []
  }
}

enum TerminalClipboardConsent {
  static func isApproved(_ response: NSApplication.ModalResponse) -> Bool {
    response == .alertSecondButtonReturn
  }

  static func requestAccess(
    for request: ghostty_clipboard_request_e,
    text: String
  ) -> Bool {
    guard Thread.isMainThread else { return false }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Don't Allow")
    alert.addButton(withTitle: "Allow")

    switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
      alert.messageText = "Confirm Paste to Terminal"
      alert.informativeText = "This text may run commands. Review the complete text before sending it to the terminal."
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
      alert.messageText = "Allow Terminal to Read the Clipboard?"
      alert.informativeText = "A program in this terminal wants to read and receive this clipboard text."
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
      alert.messageText = "Allow Terminal to Write to the Clipboard?"
      alert.informativeText = "A program in this terminal wants to replace the clipboard with this text."
    case GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ:
      alert.messageText = "Allow Terminal to Read the Clipboard?"
      alert.informativeText = "A Kitty-protocol request wants to read and receive this clipboard text."
    case GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
      alert.messageText = "Allow Terminal to Write to the Clipboard?"
      alert.informativeText = "A Kitty-protocol request wants to replace the clipboard with this text."
    case GHOSTTY_CLIPBOARD_REQUEST_LIST:
      alert.messageText = "Allow Terminal to Inspect Clipboard Types?"
      alert.informativeText = "A program in this terminal wants to know whether plain text is available on the clipboard."
    default:
      return false
    }

    if request != GHOSTTY_CLIPBOARD_REQUEST_LIST {
      alert.accessoryView = textPreview(text)
    }
    return isApproved(alert.runModal())
  }

  private static func textPreview(_ text: String) -> NSView {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    let textView = NSTextView(frame: scrollView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.string = text
    textView.textContainerInset = NSSize(width: 6, height: 6)
    scrollView.documentView = textView
    return scrollView
  }
}
