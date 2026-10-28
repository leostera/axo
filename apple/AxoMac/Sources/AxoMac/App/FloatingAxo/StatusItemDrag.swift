import AppKit

/// Dragging Axo out of the menu bar. SwiftUI's menu bar item opens its menu as soon as the mouse
/// goes down, so this watches presses on it first: one that moves is a drag, which pulls Axo out
/// (`FloatingAxo`); one that does not is handed on, and the menu opens as before.
@MainActor
enum StatusItemDrag {
  private static var monitor: Any?

  static func install() {
    guard monitor == nil else { return }
    FloatingAxo.shared.home = { statusBarWindow()?.frame }
    FloatingAxo.shared.menuBarAppearance = { statusBarWindow()?.effectiveAppearance }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
      guard let window = event.window, isStatusBarWindow(window) else { return event }
      return track(from: event) ? nil : event
    }
  }

  /// Follows the press until it lets go; true if it became a drag (and so was handled here).
  private static func track(from down: NSEvent) -> Bool {
    let start = NSEvent.mouseLocation
    var dragging = false
    while let event = NSApp.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true)
    {
      let point = NSEvent.mouseLocation
      switch event.type {
      case .leftMouseDragged:
        if !dragging, DragThreshold.isDrag(from: start, to: point) {
          dragging = true
          FloatingAxo.shared.pluck(at: point)
        }
        if dragging { FloatingAxo.shared.drag(to: point) }
      case .leftMouseUp:
        if dragging { FloatingAxo.shared.letGo(at: point) }
        return dragging
      default:
        break
      }
    }
    return dragging
  }

  private static func isStatusBarWindow(_ window: NSWindow) -> Bool {
    String(describing: type(of: window)) == "NSStatusBarWindow"
  }

  private static func statusBarWindow() -> NSWindow? {
    NSApp.windows.first(where: isStatusBarWindow)
  }
}
