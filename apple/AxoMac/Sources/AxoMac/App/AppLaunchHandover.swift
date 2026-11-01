import AppKit
import AxoDaemonManager
import OSLog

/// Runs before SwiftUI starts, so exactly one Axo runs and it is launchd's
/// (`AppAgentController`): an Axo the person opens hands over to it and exits.
@MainActor
enum AppLaunchHandover {
  private static let logger = Logger(subsystem: "dev.leostera.axo", category: "app-agent")

  /// Whether launchd's Axo should open its terminal window although it started `--background`:
  /// the Axo the person opened asked for it as it handed over.
  private(set) static var showTerminalRequested = false

  static func run() {
    let agent = AppAgentController()
    let current = agent.currentInstance()
    let decision = LaunchHandover.decide(
      isAgentJob: AppAgentController.isAgentJob,
      replaceRequested: CommandLine.arguments.contains(AppAgentController.replaceRunningArgument),
      current: current,
      others: agent.otherInstances())
    logger.info("event=app_launch.handover decision=\(String(describing: decision), privacy: .public)")

    switch decision {
    case .runHere:
      showTerminalRequested = agent.consumeShowTerminalRequest()
    case .showRunning(let pid):
      agent.requestShowTerminal()
      NSRunningApplication(processIdentifier: pid)?.activate()
      exit(0)
    case .replace(let running, let askFirst):
      if askFirst, !confirmReplacing(running, with: current) {
        agent.requestShowTerminal()
        running.first.flatMap { NSRunningApplication(processIdentifier: $0.pid) }?.activate()
        exit(0)
      }
      handOver(agent, replacing: running)
    case .startAgent:
      handOver(agent, replacing: [])
    }
  }

  /// On success the Axo launchd started takes over and this one exits; otherwise this one runs
  /// on its own, without coming back after a crash, and says why.
  private static func handOver(_ agent: AppAgentController, replacing: [AxoInstance]) {
    do {
      let pid = try agent.handOver(replacing: replacing)
      agent.requestShowTerminal()
      NSRunningApplication(processIdentifier: pid)?.activate()
      exit(0)
    } catch {
      logger.error(
        "event=app_launch.handover_failed reason=\(error.localizedDescription, privacy: .public)")
      showTerminalRequested = true
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Axo will run without restarting itself"
      alert.informativeText =
        "\(error.localizedDescription)\n\nUntil then Axo works as usual, but won’t open at login or come back if it crashes."
      alert.addButton(withTitle: "OK")
      if error as? AppAgentError == .requiresApproval {
        alert.addButton(withTitle: "Open Login Items")
      }
      activate()
      if alert.runModal() == .alertSecondButtonReturn { agent.openLoginItemsSettings() }
    }
  }

  private static func confirmReplacing(_ running: [AxoInstance], with current: AxoInstance) -> Bool {
    let alert = NSAlert()
    alert.messageText =
      "Replace the running Axo with build \(current.build ?? "unknown")?"
    let describing = running.map { instance in
      "build \(instance.build ?? "unknown")"
        + (instance.bundlePath.map { " at \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "")
    }.joined(separator: ", ")
    alert.informativeText =
      "Axo \(describing) is running. Replacing it restarts axod if its build changed: terminals restart and Pi sessions resume."
    alert.addButton(withTitle: "Replace")
    alert.addButton(withTitle: "Keep the Running Axo")
    activate()
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func activate() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// Quitting Axo for good is the menu's Quit Axo; ⌘Q and closing windows leave it running in the
/// menu bar. A crash or a kill brings it back (`dev.leostera.axo.app`); Quit Axo does not.
@MainActor
enum AppQuit {
  private(set) static var isQuittingForGood = false

  static func quitForGood() {
    isQuittingForGood = true
    NSApp.terminate(nil)
  }

  static func closeWindows() {
    for window in NSApp.windows where window.isVisible && window.canBecomeMain {
      window.performClose(nil)
    }
  }

  /// What `applicationShouldTerminate` answers: quit for Quit Axo and for logging out,
  /// restarting or shutting down; otherwise close the windows and keep running.
  static func shouldTerminate() -> NSApplication.TerminateReply {
    if isQuittingForGood || isSessionEnding() { return .terminateNow }
    closeWindows()
    return .terminateCancel
  }

  /// A quit Apple Event that says why (log out, restart, shut down) comes from the system.
  private static func isSessionEnding() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication
    else { return false }
    return event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
      || event.paramDescriptor(forKeyword: kAEQuitReason) != nil
  }
}

/// Offers to restart into a newer Axo installed over the running one's bundle (a new build at
/// dist/Axo.app): opening that path only brings this Axo forward, since macOS takes it for the
/// app already running.
@MainActor
enum InstalledUpdateCheck {
  private static var declinedBuild: String?

  static func offerRestartIfUpdated() {
    let bundle = Bundle.main.bundleURL
    guard let running = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
      let installed = AppAgentController.installedBuild(of: bundle),
      installed != running, installed != declinedBuild
    else { return }
    let alert = NSAlert()
    alert.messageText = "Restart into Axo build \(installed)?"
    alert.informativeText =
      "Build \(installed) is installed; this is build \(running). Restarting restarts axod if its build changed: terminals restart and Pi sessions resume."
    alert.addButton(withTitle: "Restart")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else {
      declinedBuild = installed
      return
    }
    // The new Axo replaces this one (and asks it to quit) without asking again.
    AppUpgradeModel.shared.restart(into: Int(installed) ?? 0)
  }
}
