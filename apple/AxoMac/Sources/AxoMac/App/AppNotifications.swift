import Foundation
import UserNotifications

/// One delegate routes application notifications; one feature must not replace another's delegate.
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = AppNotifications()

  func install() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(identifier: AppUpgradeNotificationRoute.category,
        actions: [UNNotificationAction(identifier: AppUpgradeNotificationRoute.upgradeAction,
          title: "Upgrade Axo", options: [.foreground])], intentIdentifiers: []),
      UNNotificationCategory(identifier: ElicitationNotifications.category, actions: [], intentIdentifiers: []),
    ])
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let category = notification.request.content.categoryIdentifier
    completionHandler([AppUpgradeNotificationRoute.category, ElicitationNotifications.category].contains(category) ? [.banner, .list] : [])
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    let category = response.notification.request.content.categoryIdentifier
    let identifier = response.actionIdentifier
    Task { @MainActor in
      if category == ElicitationNotifications.category {
        if identifier == UNNotificationDefaultActionIdentifier { ElicitationNotifications.shared.openInbox() }
        return
      }
      switch AppUpgradeNotificationRoute.action(category: category, identifier: identifier) {
      case .ignore: break
      case .offer: AppUpgradeModel.shared.checkForUpdates(askFirst: true)
      case .upgrade: AppUpgradeModel.shared.checkForUpdates(askFirst: false)
      }
    }
    completionHandler()
  }
}
