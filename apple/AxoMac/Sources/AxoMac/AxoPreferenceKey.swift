import Foundation

/// Every user-default key the app owns. Keys are versioned; never reuse a retired key.
enum AxoPreferenceKey {
  static let sidebarIsCollapsed = "terminalSidebarIsCollapsed.v2"
  static let selectedSession = "terminalSelectedSession.v1"
  static let automaticPiRestart = "agent.autoRestartUnavailablePi.v1"
  static let appearanceTheme = "appearance.theme"
  static let scrollSensitivity = "terminalScrollSensitivity"
  static let preventSystemSleep = "preventSystemSleep"
}
