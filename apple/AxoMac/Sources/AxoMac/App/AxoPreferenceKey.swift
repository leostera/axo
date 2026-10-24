import Foundation

/// Every user-default key the app owns. Keys are versioned; never reuse a retired key.
/// Daemon registration keys live in `DaemonPreferenceKey` and must not overlap these.
enum AxoPreferenceKey {
  static let sidebarIsCollapsed = "terminalSidebarIsCollapsed.v2"
  static let selectedSession = "terminalSelectedSession.v1"
  static let automaticPiRestart = "agent.autoRestartUnavailablePi.v1"
  static let appearanceTheme = "appearance.theme"
  static let scrollSensitivity = "terminalScrollSensitivity"
  static let preventSystemSleep = "preventSystemSleep"

  static let all = [
    sidebarIsCollapsed, selectedSession, automaticPiRestart, appearanceTheme, scrollSensitivity,
    preventSystemSleep,
  ]
}
