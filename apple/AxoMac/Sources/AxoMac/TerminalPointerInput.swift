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
