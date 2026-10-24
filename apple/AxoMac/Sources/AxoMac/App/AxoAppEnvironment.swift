import AxoDaemonManager
import Foundation

/// Process-level launch configuration. Release builds only ever produce `production`; the
/// `AxoMacTestHost` build (compiled with `AXO_TEST_HOST`) adds fixture modes in `TestHost/`.
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

  static func current(daemon: DaemonController) -> AxoAppEnvironment {
    #if AXO_TEST_HOST
      testHost(daemon: daemon)
    #else
      production(daemon: daemon)
    #endif
  }
}
