import AppKit
import AxoDaemonManager
import AxoProtocol
import OSLog

/// Offers, once axod is up, to let it run as a developer tool.
///
/// macOS scans every new program before its first run, unless the process responsible for it is
/// a developer tool. Everything Sessions run (builds, tests, Pi's tools) is axod's, so letting
/// axod in makes all of it faster. macOS has no prompt for this: the person adds axod in System
/// Settings › Privacy & Security › Developer Tools, so Axo opens that pane and shows axod in
/// Finder, ready to drag into the list. (Automation, which does prompt, axod asks for itself
/// when it starts: the prompts must name axod, not Axo.)
@MainActor
enum DeveloperToolsPrompt {
  static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_DevTools")!

  /// axod inside this Axo: what the person adds to the list.
  static var axodURL: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/axod") }

  private static let logger = Logger(subsystem: "dev.leostera.axo", category: "permissions")
  private static var offered = false

  /// Waits for axod to come up and say how it stands, then asks once per launch unless the
  /// person said not to ask again.
  static func offerWhenReady(daemon: DaemonController, defaults: UserDefaults = .standard) {
    guard !offered, !defaults.bool(forKey: AxoPreferenceKey.developerToolsPromptDeclined) else { return }
    offered = true
    Task {
      // axod may take a while to restore its Sessions; give up quietly after two minutes.
      for _ in 0..<240 where !(daemon.status.isRunning && daemon.health != nil) {
        try? await Task.sleep(for: .milliseconds(500))
      }
      guard let state = daemon.health?.developerTools else { return }
      logger.info("event=permissions.developer_tools state=\(state.rawValue, privacy: .public)")
      guard state != .granted else { return }
      present(defaults: defaults)
    }
  }

  private static func present(defaults: UserDefaults) {
    let alert = NSAlert()
    alert.messageText = "Let Axo run developer tools at full speed"
    alert.informativeText = """
      macOS checks every new program before it first runs. Allowed as a developer tool, axod \
      skips that check for what your Sessions run, so builds and tests start faster.

      In Privacy & Security › Developer Tools, click +, or drag in axod from the Finder window \
      Axo opens, and turn it on.
      """
    alert.addButton(withTitle: "Open Settings")
    alert.addButton(withTitle: "Not Now")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask again"
    NSApp.activate(ignoringOtherApps: true)
    let answer = alert.runModal()
    if alert.suppressionButton?.state == .on {
      defaults.set(true, forKey: AxoPreferenceKey.developerToolsPromptDeclined)
    }
    guard answer == .alertFirstButtonReturn else { return }
    NSWorkspace.shared.activateFileViewerSelecting([axodURL])
    NSWorkspace.shared.open(settingsURL)
  }
}
