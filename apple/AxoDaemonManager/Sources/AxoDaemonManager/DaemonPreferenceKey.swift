import Foundation

/// User-default keys owned by the daemon lifecycle. App keys live in `AxoPreferenceKey`; the two
/// sets must never overlap. Never reuse a retired key.
public enum DaemonPreferenceKey {
  /// The app asked macOS to register the LaunchAgent at least once.
  public static let registrationRequested = "dev.leostera.axo.axod.registrationRequested"
  /// Registration was observed to succeed at least once.
  public static let registrationSucceeded = "dev.leostera.axo.axod.registrationSucceeded"

  /// The `LaunchAgentDefinition` (JSON) launchd was last given; see `RestartMethod`.
  public static let registeredDefinition = "dev.leostera.axo.axod.registeredDefinition"

  /// The `LaunchAgentDefinition` (JSON) of Axo's own agent, `dev.leostera.axo.app`.
  public static let appAgentRegisteredDefinition = "dev.leostera.axo.app.registeredDefinition"
  /// When an Axo opened by the person handed over to launchd's Axo (seconds since 1970): that
  /// Axo, started `--background`, opens its terminal window anyway; see `AppAgentController`.
  public static let showTerminalRequestedAt = "dev.leostera.axo.app.showTerminalRequestedAt"

  public static let all = [
    registrationRequested, registrationSucceeded, registeredDefinition,
    appAgentRegisteredDefinition, showTerminalRequestedAt,
  ]
}
