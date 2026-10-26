import AppKit
import Observation
import SwiftUI

/// Every way of bringing the terminal up (launch, the menu bar, the Dock) goes through here, so
/// a closed terminal always comes back by way of the launch splash; an open one is only focused.
@MainActor
enum TerminalWindowOpener {
  static let windowID = "terminal"

  static var isOpen: Bool {
    NSApp.windows.contains { window in
      window.isVisible && window.identifier?.rawValue.hasPrefix(windowID) == true
    }
  }

  /// True from launch until the splash first gives way. SwiftUI may open the terminal window by
  /// itself at launch; while this holds, that window is kept hidden for the splash to reveal.
  static var heldForSplash = false
  /// The terminal window kept hidden for the splash, if SwiftUI opened one.
  static weak var heldWindow: NSWindow?

  static func open(_ openWindow: OpenWindowAction, viaSplash: Bool) {
    openWindow(id: viaSplash && !isOpen ? LaunchSplashView.windowID : windowID)
  }

  /// Shows the terminal window: a held one is brought back, otherwise SwiftUI opens it.
  static func reveal(_ openWindow: OpenWindowAction) {
    heldForSplash = false
    if let held = heldWindow {
      heldWindow = nil
      held.alphaValue = 1
      held.makeKeyAndOrderFront(nil)
    } else {
      openWindow(id: windowID)
    }
  }
}

/// Put on the terminal window's content: if the window appears while the splash is pending, it
/// is hidden before it draws and the splash is opened instead.
struct TerminalSplashHold: NSViewRepresentable {
  var openSplash: () -> Void

  func makeNSView(context: Context) -> HoldView {
    let view = HoldView()
    view.openSplash = openSplash
    return view
  }

  func updateNSView(_ nsView: HoldView, context: Context) {}

  final class HoldView: NSView {
    var openSplash: (() -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      guard let newWindow, TerminalWindowOpener.heldForSplash else { return }
      newWindow.alphaValue = 0
      TerminalWindowOpener.heldWindow = newWindow
      let openSplash = openSplash
      DispatchQueue.main.async {
        guard TerminalWindowOpener.heldForSplash else { return }
        newWindow.orderOut(nil)
        openSplash?()
      }
    }
  }
}

/// Dock clicks with no window open, handed from the app delegate to a view that can open windows.
@MainActor
@Observable
final class TerminalReopenRequests {
  static let shared = TerminalReopenRequests()
  private(set) var revision = 0

  func request() {
    revision &+= 1
  }
}
