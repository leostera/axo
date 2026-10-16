import AppKit

@MainActor
final class AxoURLSchemeDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      _ = PairingLinkRouter.shared.receive(url)
    }
  }
}
