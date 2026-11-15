import AppKit

/// Deliberately uses the primary screen's usable frame, not NSScreen.main (the key window's
/// display). Geometry is independent of the desktop so fixture tests never open a real window.
enum AppWindowPlacement {
  static func centered(size: NSSize, in visibleFrame: NSRect) -> NSRect {
    let width = min(size.width, max(1, visibleFrame.width - 32))
    let height = min(size.height, max(1, visibleFrame.height - 32))
    return NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
      width: width, height: height)
  }
  @MainActor
  static func applyAppAppearance(_ window: NSWindow) {
    switch UserDefaults.standard.string(forKey: AxoPreferenceKey.appearanceTheme) {
    case "dark": window.appearance = NSAppearance(named: .darkAqua)
    case "light": window.appearance = NSAppearance(named: .aqua)
    default: window.appearance = nil
    }
  }
  @MainActor
  static func centerOnPrimaryScreen(_ window: NSWindow) {
    guard let visible = NSScreen.screens.first?.visibleFrame else { window.center(); return }
    window.setFrame(centered(size: window.frame.size, in: visible), display: false)
  }
}
