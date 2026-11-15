import AppKit
import AxoClient
import AxoDaemonManager
import AxoProtocol
import ServiceManagement
import UserNotifications

/// Constructed only by normal app startup. Fixture views inject every effect instead.
@MainActor
enum AppSetupLive {
  static weak var daemon: DaemonController?
  static var effects: AppSetupEffects {
    AppSetupEffects(check: check, fix: fix, connectionStatus: {
      let socket = try DaemonController.socketPath()
      let health = try await AxodConnection.withFreshConnection(to: socket) { try await $0.health() }
      let account = try? await AxodConnection.withFreshConnection(to: socket) { try await $0.remoteAccessStatus() }
      return SetupConnectionStatus(health: health, account: SetupAccountStatus(account))
    }, guide: { item, recheck, granted in
      try AppPermissionGuide.shared.show(item: item,
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod"),
        recheck: recheck, granted: granted)
    }, openTerminal: { TerminalReopenRequests.shared.request() },
      restartDaemon: { daemon?.restartDaemon() }, openPairing: { PairingLinkRouter.shared.showSettings() })
  }

  static func check() async -> SetupSnapshot {
    var health: DaemonHealth?
    var permissions: DaemonPermissions?
    var detail: String?
    do {
      let socket = try DaemonController.socketPath()
      health = try await AxodConnection.withFreshConnection(to: socket) { try await $0.health() }
      permissions = try await AxodConnection.withFreshConnection(to: socket) { try await $0.permissions() }
    } catch {
      detail = "Couldn’t read axod’s complete permission report. Check Login Items and use the latest Axo, then recheck."
    }
    let notification = await notificationStatus()
    let cli = CLICommandInstallation.shared
    cli.refresh()
    let command: SetupStatus = switch cli.status {
    case .installed: .ready
    case .missing: .needsSetup
    case .conflict: .unknown
    case .unavailable: .unsupported
    }
    let login = SMAppService.agent(plistName: "dev.leostera.axo.app.plist").status == .enabled
      && SMAppService.agent(plistName: "dev.leostera.axo.axod.plist").status == .enabled
    return SetupSnapshot(health: health, permissions: permissions, loginItemsEnabled: login,
      notifications: notification, commandLine: cli.isInstalling ? .checking : command, detail: detail)
  }

  private static func notificationStatus() async -> SetupStatus {
    await withCheckedContinuation { continuation in
      let pending = NotificationReply(continuation)
      pending.deadline = Task {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        pending.finish(.unknown)
      }
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let value: SetupStatus
        switch settings.authorizationStatus {
        case .authorized:
          value = settings.alertSetting == .enabled ? .ready
            : settings.notificationCenterSetting == .enabled ? .quiet : .needsSetup
        case .provisional: value = .quiet
        case .denied, .notDetermined: value = .needsSetup
        @unknown default: value = .unknown
        }
        Task { @MainActor in pending.finish(value) }
      }
    }
  }

  /// Main-actor arbitration bounds the OS callback without double-resuming a timed-out check.
  @MainActor
  final class NotificationReply {
    var continuation: CheckedContinuation<SetupStatus, Never>?
    var deadline: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<SetupStatus, Never>) { self.continuation = continuation }
    func finish(_ value: SetupStatus) {
      guard let continuation else { return }
      self.continuation = nil
      deadline?.cancel()
      deadline = nil
      continuation.resume(returning: value)
    }
  }

  private static func fix(_ item: SetupItem) async throws {
    switch item {
    case .background:
      if daemon?.status == .disabled { daemon?.enableDaemon() }
      else { SMAppService.openSystemSettingsLoginItems() }
    case .notifications:
      let center = UNUserNotificationCenter.current()
      if await center.notificationSettings().authorizationStatus == .notDetermined {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
      } else {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.leostera.axo")!
        guard NSWorkspace.shared.open(url) else { throw failure("Open System Settings → Notifications → Axo.") }
      }
    case .finder, .systemEvents:
      let report = try await AxodConnection.withFreshConnection(to: DaemonController.socketPath()) { try await $0.permissions() }
      let state = item == .finder ? report.automationFinder : report.automationSystemEvents
      if state == .notGranted {
        _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
      } else {
        _ = try await AxodConnection.withFreshConnection(to: DaemonController.socketPath()) {
          try await $0.requestAutomationPermission(item == .finder ? .finder : .systemEvents)
        }
      }
    case .commandLine:
      await CLICommandInstallation.shared.install()
      if let error = CLICommandInstallation.shared.failure { throw failure(error) }
      guard CLICommandInstallation.shared.status == .installed else {
        throw failure("The command location is unavailable or contains another file. Review Command Line in General Settings; nothing was replaced.")
      }
    default: break // Settings/drag repairs are handled by the guide, never by an OS request here.
    }
  }
  private static func failure(_ text: String) -> NSError {
    NSError(domain: "dev.leostera.axo.setup", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }
}
