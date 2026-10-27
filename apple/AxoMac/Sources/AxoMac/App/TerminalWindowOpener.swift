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

  /// True while the splash owns the screen: from launch, and whenever Axod stops running, until
  /// the splash gives way. While it holds, the terminal window is kept hidden.
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

/// Put on the terminal window's content: whenever the window shows while the splash is pending
/// (at launch) or while Axod isn't running (starting, restarting, gone), it is hidden before it
/// draws and the splash opens instead; the splash brings it back once Axod is up.
struct TerminalSplashHold: NSViewRepresentable {
  var daemonRunning: Bool
  var openSplash: () -> Void

  func makeNSView(context: Context) -> HoldView {
    let view = HoldView()
    view.openSplash = openSplash
    view.daemonRunning = daemonRunning
    return view
  }

  func updateNSView(_ nsView: HoldView, context: Context) {
    nsView.openSplash = openSplash
    nsView.daemonRunning = daemonRunning
  }

  final class HoldView: NSView {
    var openSplash: (() -> Void)?
    var daemonRunning = true {
      didSet { if !daemonRunning, oldValue, let window { holdForSplash(window) } }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      guard let newWindow, TerminalWindowOpener.heldForSplash || !daemonRunning else { return }
      holdForSplash(newWindow)
    }

    private func holdForSplash(_ window: NSWindow) {
      TerminalWindowOpener.heldForSplash = true
      TerminalWindowOpener.heldWindow = window
      window.alphaValue = 0
      let openSplash = openSplash
      DispatchQueue.main.async {
        guard TerminalWindowOpener.heldForSplash else { return }
        window.orderOut(nil)
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
