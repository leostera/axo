import AppKit

@MainActor
final class AxoURLSchemeDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchBoot.scheduleFallback()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      _ = PairingLinkRouter.shared.receive(url)
    }
  }

  /// A Dock click with no window open brings the terminal back through the splash; SwiftUI's
  /// own handling would open a window scene directly.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { TerminalReopenRequests.shared.request() }
    return false
  }
}
