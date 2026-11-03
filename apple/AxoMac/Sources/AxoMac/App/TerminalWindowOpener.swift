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

/// Put on the terminal window's content: the terminal shows only a fully operational Axod
/// (`LaunchSplashGate.terminalHold`). Whenever the window would show while the splash is pending
/// (at launch) or Axod isn't operational (starting, updating, restarting, gone, its catalog
/// down), it is hidden before it draws and the splash opens instead; the splash brings it back
/// once Axod is operational again.
struct TerminalSplashHold: NSViewRepresentable {
  var hold: LaunchSplashGate.TerminalHold
  var openSplash: () -> Void

  func makeNSView(context: Context) -> HoldView {
    let view = HoldView()
    view.openSplash = openSplash
    view.hold = hold
    return view
  }

  func updateNSView(_ nsView: HoldView, context: Context) {
    nsView.openSplash = openSplash
    nsView.hold = hold
  }

  final class HoldView: NSView {
    var openSplash: (() -> Void)?
    var hold = LaunchSplashGate.TerminalHold.show {
      didSet { if hold != oldValue { apply() } }
    }
    /// How long a catalog outage is waited out (`LaunchSplashGate.catalogOutageGrace`).
    var grace = LaunchSplashGate.catalogOutageGrace
    /// The hold waiting out `grace`.
    private var pendingHold: DispatchWorkItem?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      guard let newWindow else { return }
      // Opened while Axod isn't operational, even within the grace: straight to the splash.
      if TerminalWindowOpener.heldForSplash || hold != .show { holdForSplash(newWindow) }
    }

    private func apply() {
      switch hold {
      case .show:
        pendingHold?.cancel()
        pendingHold = nil
      case .holdNow:
        pendingHold?.cancel()
        pendingHold = nil
        if let window { holdForSplash(window) }
      case .holdAfterGrace:
        guard pendingHold == nil else { return }
        let work = DispatchWorkItem { [weak self] in
          guard let self else { return }
          self.pendingHold = nil
          if self.hold != .show, let window = self.window { self.holdForSplash(window) }
        }
        pendingHold = work
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
      }
    }

    private func holdForSplash(_ window: NSWindow) {
      // Already given way to the splash.
      guard !(TerminalWindowOpener.heldForSplash && TerminalWindowOpener.heldWindow === window)
      else { return }
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
