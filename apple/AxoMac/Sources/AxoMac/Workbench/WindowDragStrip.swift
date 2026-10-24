import AppKit
import SwiftUI

/// The window draws its content under the hidden title bar, so the sidebar starts with this strip:
/// it reserves room for the traffic-light buttons and behaves like a title bar (drag to move,
/// double-click to zoom, following the user's title-bar double-click preference).
struct WindowDragStrip: NSViewRepresentable {
  static let height: CGFloat = 28
  /// Wide enough that the close/minimize/zoom buttons never overlap the terminal.
  static let minimumSidebarWidth: CGFloat = 76

  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      if event.clickCount == 2 {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
        return
      }
      window.performDrag(with: event)
    }
  }
}
