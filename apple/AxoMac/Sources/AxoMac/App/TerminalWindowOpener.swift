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

  static func open(_ openWindow: OpenWindowAction, viaSplash: Bool) {
    openWindow(id: viaSplash && !isOpen ? LaunchSplashView.windowID : windowID)
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
