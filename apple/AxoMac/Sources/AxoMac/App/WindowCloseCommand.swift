import AppKit

/// A remembered pane selection must never redirect Close away from the key window.
@MainActor
enum WindowCloseCommand {
  static func perform(keyWindow: NSWindow?, closeFocusedPane: () -> Bool) {
    guard let window = keyWindow else { return }
    // A modal question owns this interaction; never close the pane behind it.
    guard !window.isSheet, window.attachedSheet == nil else { return }
    if window.identifier?.rawValue.hasPrefix(TerminalWindowOpener.windowID) == true,
      closeFocusedPane() { return }
    window.performClose(nil)
  }
}
