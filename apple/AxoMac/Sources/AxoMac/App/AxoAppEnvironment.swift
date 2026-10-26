import AxoDaemonManager
import Foundation

/// Process-level launch configuration. The shipped app uses `ProductionLaunch`; the separate
/// `AxoMacTestHost` entry target (Sources/AxoMacTestHost) supplies fixture launch modes.
@MainActor
struct AxoAppEnvironment {
  var sessions: TerminalSessionsModel
  /// Whether Axod is reachable; read under observation tracking, so it must read observable state.
  var daemonIsRunning: @MainActor () -> Bool
  /// Re-verifies the daemon when the catalog stream keeps failing.
  var daemonUnreachable: @MainActor () -> Void = {}
  /// Whether to register/connect the installed LaunchAgent helper.
  var startsDaemon = true
  /// Whether launching opens the terminal window automatically.
  var opensTerminalWindow = true
  /// Whether that opening goes through the launch splash, which waits for Axod and the catalog.
  var showsLaunchSplash = true
  /// Extra setup once the terminal window exists (fixtures only).
  var prepareTerminalWindow: @MainActor (TerminalSessionsModel, GhosttyRuntime) async -> Void = {
    _, _ in
  }

  static func production(daemon: DaemonController) -> AxoAppEnvironment {
    AxoAppEnvironment(
      sessions: TerminalSessionsModel(),
      daemonIsRunning: { daemon.status.isRunning },
      daemonUnreachable: { daemon.checkHealth() })
  }
}

/// Chooses the environment an `AxoApp` launches with. Each executable picks one at its entry
/// point, so test-only modes never exist in the shipped binary.
protocol AxoLaunchMode {
  @MainActor static func environment(daemon: DaemonController) -> AxoAppEnvironment
}

enum ProductionLaunch: AxoLaunchMode {
  static func environment(daemon: DaemonController) -> AxoAppEnvironment {
    .production(daemon: daemon)
  }
}

/// The shipped app's entry point, called from the `AxoMacMain` target.
public enum AxoAppEntryPoint {
  @MainActor public static func main(mascot: (any MascotAnimation)? = nil) {
    AxoMascot.installedAnimation = mascot
    AxoApp<ProductionLaunch>.main()
  }
}
