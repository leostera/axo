import AppKit
import AxoDaemonManager
import UserNotifications

/// Only our update category can route a notification to the upgrader; terminal content cannot.
enum AppUpgradeNotificationRoute {
  static let category = "axo.upgrade.available"
  static let upgradeAction = "axo.upgrade.install"
  static let lastNotifiedKey = "upgrade.lastNotifiedBuild"

  enum Action: Equatable { case ignore, offer, upgrade }

  static func action(category: String, identifier: String) -> Action {
    guard category == self.category else { return .ignore }
    switch identifier {
    case upgradeAction: return .upgrade
    case UNNotificationDefaultActionIdentifier: return .offer
    default: return .ignore
    }
  }
}

/// Quiet, local macOS banners from the updater's existing startup/hourly checks. No APNs service.
/// Delivery is injected so tests never ask permission or post on the person's desktop.
@MainActor
final class AppUpgradeNotifications {
  static let shared = AppUpgradeNotifications(
    defaults: .standard,
    authorize: {
      let state = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
      return state == .authorized || state == .provisional
    },
    deliver: { request in try await UNUserNotificationCenter.current().add(request) },
    isCurrent: { build in
      !AppUpgradeModel.shared.automatic.isEnabled && AppUpgradeModel.shared.phase == .idle
        && AppUpgradeModel.shared.available?.build == build
    })

  private let defaults: UserDefaults
  private let authorize: () async -> Bool
  private let deliver: (UNNotificationRequest) async throws -> Void
  private let isCurrent: (Int) -> Bool
  private var sending = false
  private let now: () -> Date

  init(defaults: UserDefaults, authorize: @escaping () async -> Bool,
    deliver: @escaping (UNNotificationRequest) async throws -> Void,
    isCurrent: @escaping (Int) -> Bool, now: @escaping () -> Date = Date.init)
  {
    self.defaults = defaults
    self.authorize = authorize
    self.deliver = deliver
    self.isCurrent = isCurrent
    self.now = now
  }

  func notify(_ upgrade: AppUpgrade, running: Int) async {
    guard upgrade.build > running, !sending,
      AppUpdateReminder.mayNotify(build: upgrade.build, defaults: defaults, now: now()) else { return }
    sending = true
    defer { sending = false }
    guard await authorize(), isCurrent(upgrade.build),
      AppUpdateReminder.mayNotify(build: upgrade.build, defaults: defaults, now: now()) else { return }
    let content = UNMutableNotificationContent()
    content.title = upgrade.version.map { "Axo \($0) is available" } ?? "A new version of Axo is available"
    content.body = "Upgrade when you’re ready from the Axo menu."
    content.categoryIdentifier = AppUpgradeNotificationRoute.category
    // One replaceable banner, no sound, and a persisted high-water mark only after successful add.
    let request = UNNotificationRequest(identifier: AppUpgradeNotificationRoute.category, content: content, trigger: nil)
    do {
      try await deliver(request)
      AppUpdateReminder.delivered(build: upgrade.build, defaults: defaults)
    } catch {
      // The next ordinary check may retry; notification failure never blocks the menu's updater.
    }
  }

}
