import AxoProtocol
import Foundation

/// UI state is an observation, never a grant consumed by computer-use or other authorization.
enum SetupStatus: String, Equatable, Sendable {
  case checking, ready, needsSetup, quiet, notRunning, unknown, unsupported
  var title: String {
    switch self {
    case .checking: "Checking…"
    case .ready: "Allowed"
    case .needsSetup: "Not enabled"
    case .quiet: "Quiet delivery"
    case .notRunning: "Not running"
    case .unknown: "Not verified"
    case .unsupported: "Unavailable"
    }
  }
  var isReady: Bool { self == .ready }
  init(_ access: PermissionAccess) {
    self = switch access {
    case .granted: .ready
    case .notGranted, .notAsked: .needsSetup
    case .notRunning: .notRunning
    case .unknown: .unknown
    case .unsupported: .unsupported
    }
  }
}

enum SetupItem: String, CaseIterable, Identifiable {
  case background, accessibility, screenRecording, developerTools, fullDiskAccess
  case finder, systemEvents, notifications, commandLine
  var id: String { rawValue }
  var title: String {
    switch self {
    case .background: "Background service"
    case .accessibility: "Accessibility & input control"
    case .screenRecording: "Screen recording"
    case .developerTools: "Developer Tools"
    case .fullDiskAccess: "Protected files"
    case .finder: "Finder automation"
    case .systemEvents: "System Events automation"
    case .notifications: "Notifications"
    case .commandLine: "Command line"
    }
  }
  var purpose: String {
    switch self {
    case .background: "Keeps Sessions running and starts Axo at login"
    case .accessibility: "Lets axod read app controls and send keyboard and pointer input"
    case .screenRecording: "Lets axod capture app windows for computer use; no audio is recorded"
    case .developerTools: "Lets axod run your developer tools without macOS’s first-run scans"
    case .fullDiskAccess: "Optional: lets axod’s tools work with protected files"
    case .finder: "Lets axod’s scripts work with Finder"
    case .systemEvents: "Lets axod’s scripts work with System Events"
    case .notifications: "Lets Axo show Session alerts and update notices; Focus still applies"
    case .commandLine: "Optional: use axo from Terminal; app updates update the command too"
    }
  }
  var icon: String {
    switch self {
    case .background: "bolt"
    case .accessibility: "accessibility"
    case .screenRecording: "rectangle.dashed.badge.record"
    case .developerTools: "hammer"
    case .fullDiskAccess: "folder"
    case .finder: "macwindow"
    case .systemEvents: "gearshape.2"
    case .notifications: "bell"
    case .commandLine: "terminal"
    }
  }
  var settingsURL: URL? {
    let pane: String? = switch self {
    case .accessibility: "Privacy_Accessibility"
    case .screenRecording: "Privacy_ScreenCapture"
    case .developerTools: "Privacy_DevTools"
    case .fullDiskAccess: "Privacy_AllFiles"
    default: nil
    }
    return pane.flatMap { URL(string: "x-apple.systempreferences:com.apple.preference.security?\($0)") }
  }
}

struct SetupSnapshot {
  var health: DaemonHealth?
  var permissions: DaemonPermissions?
  var loginItemsEnabled: Bool
  var notifications: SetupStatus
  var commandLine: SetupStatus
  var detail: String?

  func status(_ item: SetupItem) -> SetupStatus {
    switch item {
    case .background: return health?.ready == true && loginItemsEnabled ? .ready : .needsSetup
    case .notifications: return notifications
    case .commandLine: return commandLine
    default: break
    }
    guard let permissions else { return .unknown }
    switch item {
    case .accessibility:
      guard permissions.accessibility == .granted else { return SetupStatus(permissions.accessibility) }
      return SetupStatus(permissions.inputControl)
    case .screenRecording: return SetupStatus(permissions.screenRecording)
    case .developerTools: return SetupStatus(permissions.developerTools)
    case .fullDiskAccess: return SetupStatus(permissions.fullDiskAccess)
    case .finder: return SetupStatus(permissions.automationFinder)
    case .systemEvents: return SetupStatus(permissions.automationSystemEvents)
    default: return .unknown
    }
  }
  var computerUseReady: Bool {
    permissions?.supported == true && permissions?.locked == false
      && status(.accessibility).isReady && status(.screenRecording).isReady
  }
}

@MainActor
struct AppSetupEffects {
  let check: () async -> SetupSnapshot
  let fix: (SetupItem) async throws -> Void
  let testConnection: () async throws -> String
  let guide: (SetupItem, @escaping () -> Void, @escaping () -> Bool) throws -> Void
  let openTerminal: () -> Void
  let restartDaemon: () -> Void
}
