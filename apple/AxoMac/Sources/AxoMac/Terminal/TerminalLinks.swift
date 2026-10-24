import AppKit
import Foundation
import GhosttyKit

enum TerminalLinkKind: Equatable {
  case unknown, text, html, osc8

  init(_ kind: ghostty_action_open_url_kind_e) {
    switch kind {
    case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: self = .text
    case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: self = .html
    case GHOSTTY_ACTION_OPEN_URL_KIND_OSC8: self = .osc8
    default: self = .unknown
    }
  }
}

/// Mirrors the pinned Ghostty.app `openURL` routing. OSC 8 and unknown-kind targets come from
/// terminal output, so they must go through `UntrustedURL`; only Ghostty-produced text/HTML
/// targets use the trusted opener.
enum TerminalLinkPolicy {
  enum Route: Equatable {
    case trusted(URL)
    case untrusted(String)
  }

  static func route(kind: TerminalLinkKind, value: String) -> Route {
    if kind == .osc8 { return .untrusted(value) }

    let url: URL
    if let candidate = URL(string: value), candidate.scheme != nil {
      url = candidate
    } else {
      url = URL(filePath: NSString(string: value).standardizingPath)
    }

    if kind == .unknown {
      // Values with unsafe characters are passed unchanged so they are rejected before
      // percent-encoding hides them.
      let hasScheme = URL(string: value)?.scheme != nil
      let target =
        hasScheme || UntrustedURL.containsUnsafeCharacters(value) ? value : url.absoluteString
      return .untrusted(target)
    }
    return .trusted(url)
  }

  /// Opens a link from Ghostty. Always reports handled so the core never retries with its
  /// unrestricted fallback opener.
  @MainActor
  static func open(kind: TerminalLinkKind, value: String) -> Bool {
    switch route(kind: kind, value: value) {
    case .trusted(let url):
      NSWorkspace.shared.open(url)
    case .untrusted(let value):
      let target = UntrustedURL(value)
      switch target.decision {
      case .allow(let url):
        NSWorkspace.shared.open(url)
      case .confirm(let url):
        UntrustedURLAlert.presentConfirmation(for: url, displayString: target.displayString)
      case .deny(let reason):
        UntrustedURLAlert.presentBlock(reason: reason, displayString: target.displayString)
      }
    }
    return true
  }

  static func string(_ pointer: UnsafePointer<CChar>?, length: Int) -> String? {
    guard let pointer, length > 0 else { return nil }
    return String(
      decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
  }
}

/// Ghostty.app's URL hover banner: the hovered link target, shown at the bottom-left of the pane.
final class TerminalLinkHoverView: NSTextField {
  init() {
    super.init(frame: .zero)
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = true
    backgroundColor = .windowBackgroundColor
    textColor = .secondaryLabelColor
    font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    lineBreakMode = .byTruncatingMiddle
    isHidden = true
    wantsLayer = true
    layer?.cornerRadius = 4
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for TerminalLinkHoverView")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(_ link: String?, in bounds: NSRect) {
    guard let link, !link.isEmpty else {
      isHidden = true
      return
    }
    // Display escaped, never raw, terminal-provided text (bidi controls, line breaks).
    stringValue = UntrustedURL(link).displayString
    sizeToFit()
    let width = min(frame.width + 8, max(bounds.width - 8, 0))
    frame = NSRect(x: 4, y: 4, width: width, height: frame.height + 2)
    isHidden = false
  }
}
