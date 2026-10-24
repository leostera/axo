import AppKit

enum TerminalKeyEquivalentPolicy {
  enum Route: Equatable {
    case axoMenu
    case ghosttyBinding
    case appKit
  }

  static func route(
    appMenuHandled: Bool,
    terminalFocused: Bool,
    ghosttyBindingMatched: Bool
  ) -> Route {
    guard terminalFocused else { return .appKit }
    if appMenuHandled { return .axoMenu }
    if ghosttyBindingMatched { return .ghosttyBinding }
    return .appKit
  }

  static func normalizedControlEquivalent(for event: NSEvent) -> String? {
    switch event.charactersIgnoringModifiers {
    case "\r":
      return event.modifierFlags.contains(.control) ? "\r" : nil
    case "/":
      guard event.modifierFlags.contains(.control),
        event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
      else { return nil }
      return "_"
    default:
      return nil
    }
  }

  static func shouldRedispatchThroughAppKit(_ event: NSEvent) -> Bool {
    event.timestamp != 0 && !event.modifierFlags.isDisjoint(with: [.command, .control])
  }

  static func shouldForwardCommandKeyUp(_ event: NSEvent) -> Bool {
    event.type == .keyUp && event.modifierFlags.contains(.command)
  }

  static func matchesRedispatch(eventTimestamp: TimeInterval, previousTimestamp: TimeInterval?) -> Bool {
    previousTimestamp == eventTimestamp
  }
}
