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
  /// Which Macs' Sessions the sidebar lists (RFD0024).
  static let sidebarMacs = "sidebar.macs.v1"
  /// Sessions pinned to the top of the sidebar, on this Mac only (`SessionPins`).
  static let pinnedSessions = "sidebar.pinnedSessions.v1"
  /// The person asked not to be offered Developer Tools again.
  static let developerToolsPromptDeclined = "permissions.developerToolsDeclined.v1"

  static let all = [
    sidebarIsCollapsed, selectedSession, automaticPiRestart, appearanceTheme, scrollSensitivity,
    preventSystemSleep, sidebarMacs, pinnedSessions, developerToolsPromptDeclined,
  ]
}
