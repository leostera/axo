import AppKit
import Foundation
import GhosttyKit

enum TerminalMouseInput {
  static func button(forEventButtonNumber number: Int) -> ghostty_input_mouse_button_e {
    switch number {
    case 0: GHOSTTY_MOUSE_LEFT
    case 1: GHOSTTY_MOUSE_RIGHT
    case 2: GHOSTTY_MOUSE_MIDDLE
    case 3: GHOSTTY_MOUSE_EIGHT
    case 4: GHOSTTY_MOUSE_NINE
    case 5: GHOSTTY_MOUSE_SIX
    case 6: GHOSTTY_MOUSE_SEVEN
    case 7: GHOSTTY_MOUSE_FOUR
    case 8: GHOSTTY_MOUSE_FIVE
    case 9: GHOSTTY_MOUSE_TEN
    case 10: GHOSTTY_MOUSE_ELEVEN
    default: GHOSTTY_MOUSE_UNKNOWN
    }
  }

  /// Ghostty.app doubles precise (trackpad/Magic Mouse) deltas; discrete wheel ticks pass through.
  static func scrollDeviceMultiplier(isPrecise: Bool) -> Double {
    isPrecise ? 2.0 : 1.0
  }

  static func scrollFlags(
    isPrecise: Bool,
    momentumPhase: NSEvent.Phase
  ) -> ghostty_input_scroll_mods_t {
    let momentum: Int32
    switch momentumPhase {
    case .began: momentum = 1
    case .stationary: momentum = 2
    case .changed: momentum = 3
    case .ended: momentum = 4
    case .cancelled: momentum = 5
    case .mayBegin: momentum = 6
    default: momentum = 0
    }
    return (momentum << 1) | (isPrecise ? 1 : 0)
  }

  /// The view a click at `locationInWindow` lands on, overlays included. `hitTest` takes a point
  /// in the receiver's superview's coordinates; Axo's content view is a flipped `NSHostingView`,
  /// so converting into the content view's own space would mirror the click vertically.
  static func view(at locationInWindow: NSPoint, in window: NSWindow) -> NSView? {
    guard let contentView = window.contentView else { return nil }
    let location =
      contentView.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
    return contentView.hitTest(location)
  }

  static func shouldConsumeFocusOnlyClick(
    surfaceIsFirstResponder: Bool,
    applicationIsActive: Bool,
    windowIsKey: Bool
  ) -> Bool {
    !surfaceIsFirstResponder && applicationIsActive && windowIsKey
  }
}

enum TerminalCursorPolicy {
  static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor? {
    switch shape {
    case GHOSTTY_MOUSE_SHAPE_DEFAULT:
      NSCursor.arrow
    case GHOSTTY_MOUSE_SHAPE_TEXT:
      NSCursor.iBeam
    case GHOSTTY_MOUSE_SHAPE_GRAB:
      NSCursor.openHand
    case GHOSTTY_MOUSE_SHAPE_GRABBING:
      NSCursor.closedHand
    case GHOSTTY_MOUSE_SHAPE_POINTER:
      NSCursor.pointingHand
    case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
      NSCursor.resizeLeft
    case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
      NSCursor.resizeRight
    case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
      NSCursor.resizeUp
    case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
      NSCursor.resizeDown
    case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
      NSCursor.resizeUpDown
    case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
      NSCursor.resizeLeftRight
    case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
      NSCursor.iBeamCursorForVerticalLayout
    case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
      NSCursor.contextualMenu
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
      NSCursor.crosshair
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
      NSCursor.operationNotAllowed
    default:
      nil
    }
  }
}

enum TerminalContextMenuItem: Equatable {
  case copy
  case paste
  case separator
  case splitRight
  case splitDown
  case closePane
}

enum TerminalContextMenuPolicy {
  static func items(hasSelection: Bool) -> [TerminalContextMenuItem] {
    var items: [TerminalContextMenuItem] = []
    if hasSelection { items.append(.copy) }
    items.append(contentsOf: [.paste, .separator, .splitRight, .splitDown, .separator, .closePane])
    return items
  }
}

enum TerminalServicesPolicy {
  static let textTypes: [NSPasteboard.PasteboardType] = [
    .string,
    NSPasteboard.PasteboardType("public.utf8-plain-text"),
  ]

  static func supports(
    sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Bool {
    (sendType.map(textTypes.contains) ?? true)
      && (returnType.map(textTypes.contains) ?? true)
  }

  static func canServe(
    sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?,
    hasSelection: Bool
  ) -> Bool {
    supports(sendType: sendType, returnType: returnType) && (sendType == nil || hasSelection)
  }
}

enum TerminalDropInput {
  static func accepts(_ types: [NSPasteboard.PasteboardType]) -> Bool {
    types.contains(.string) || types.contains(.fileURL)
  }

  /// Where dropped files that only Axo may read are copied for the terminal's programs.
  static var stagingDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("axo-drops", isDirectory: true)
  }

  /// Whether a dropped file lives where only the app that received the drag may read it.
  ///
  /// The screenshot thumbnail keeps its file under `$TMPDIR/TemporaryItems`, which macOS
  /// privacy protection opens to the drag's receiver (Axo) but not to other processes, such as
  /// Pi under Axod; the file is also deleted once the thumbnail goes away. Other files keep
  /// their real path, so a program can edit the file the user meant.
  static func needsStaging(_ url: URL) -> Bool {
    url.isFileURL && url.standardizedFileURL.pathComponents.contains("TemporaryItems")
  }

  /// `urls` with every file that needs staging replaced by a copy in `directory` that keeps its
  /// name. A file that cannot be copied keeps its original URL.
  static func staged(_ urls: [URL], in directory: URL) -> [URL] {
    urls.map { url in
      guard needsStaging(url) else { return url }
      let destination = directory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent(url.lastPathComponent)
      do {
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
      } catch {
        AxoTrace.surfaces.error(
          "event=surface.drop_staging_failed error=\(error.localizedDescription, privacy: .public)")
        return url
      }
    }
  }

  static func text(plainText: String?, fileURLs: [URL]?) -> String? {
    if let plainText, !plainText.isEmpty { return plainText }
    guard let fileURLs, !fileURLs.isEmpty, fileURLs.allSatisfy(\.isFileURL) else { return nil }
    return fileURLs.map(\.path).joined(separator: "\n")
  }
}

enum TerminalPressurePolicy {
  static func shouldShowQuickLook(
    previousStage: Int,
    currentStage: Int,
    forceClickEnabled: Bool
  ) -> Bool {
    previousStage < 2 && currentStage == 2 && forceClickEnabled
  }
}
