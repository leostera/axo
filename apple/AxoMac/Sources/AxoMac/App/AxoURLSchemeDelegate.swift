import AppKit
import AxoDaemonManager

@MainActor
final class AxoURLSchemeDelegate: NSObject, NSApplicationDelegate {
  private var observers: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchBoot.scheduleFallback()
    StatusItemDrag.install()
    observeOtherAxos()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      _ = PairingLinkRouter.shared.receive(url)
    }
  }

  /// A Dock click with no window open brings the terminal back through the splash; SwiftUI's
  /// own handling would open a window scene directly. Opening Axo.app while this Axo runs lands
  /// here too, so it is also where a newer Axo installed over this one is offered.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { TerminalReopenRequests.shared.request() }
    InstalledUpdateCheck.offerRestartIfUpdated()
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppQuit.shouldTerminate()
  }

  /// Another Axo, opened by the person, hands over to this one or replaces it; see
  /// `AppLaunchHandover`.
  private func observeOtherAxos() {
    let center = DistributedNotificationCenter.default()
    observers.append(
      center.addObserver(
        forName: AppAgentController.showTerminalNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          TerminalReopenRequests.shared.request()
          NSApp.activate(ignoringOtherApps: true)
        }
      })
    observers.append(
      center.addObserver(
        forName: AppAgentController.quitForReplacementNotification, object: nil, queue: .main
      ) { notification in
        let pids = (notification.userInfo?["pids"] as? [NSNumber])?.map(\.int32Value) ?? []
        guard pids.contains(getpid()) else { return }
        MainActor.assumeIsolated { AppQuit.quitForGood() }
      })
  }
}
