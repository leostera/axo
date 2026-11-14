import AxoDaemonManager
import UserNotifications
import XCTest

@testable import AxoMac

final class AppUpgradeNotificationTests: XCTestCase {
  @MainActor
  private func defaults() -> UserDefaults {
    let name = "dev.leostera.axo.update-test.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }

  @MainActor
  func testQuietSemanticVersionBannerAndPersistentDeduplication() async {
    let store = defaults()
    var requests: [UNNotificationRequest] = []
    var authorizations = 0
    let make = {
      AppUpgradeNotifications(defaults: store,
        authorize: { authorizations += 1; return true },
        deliver: { requests.append($0) }, isCurrent: { _ in true })
    }
    let upgrade = AppUpgrade.installed(build: 334, axodBuild: 81, version: "0.63")
    await make().notify(upgrade, running: 333)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].content.title, "Axo 0.63 is available")
    XCTAssertNil(requests[0].content.sound)
    XCTAssertEqual(requests[0].content.categoryIdentifier, AppUpgradeNotificationRoute.category)
    XCTAssertNil(requests[0].trigger)
    // A new controller (like a relaunch) still never repeats that release or an older one.
    await make().notify(upgrade, running: 333)
    await make().notify(.installed(build: 333, axodBuild: 81, version: "0.62"), running: 332)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(authorizations, 1)
    await make().notify(.installed(build: 335, axodBuild: 81, version: "0.64"), running: 333)
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].identifier, requests[1].identifier, "a newer release replaces the old banner")
  }

  @MainActor
  func testDenialOrStaleCandidateDoesNotConsumeTheNotification() async {
    let store = defaults()
    var allowed = false
    var current = true
    var deliveries = 0
    let notifier = AppUpgradeNotifications(defaults: store, authorize: { allowed },
      deliver: { _ in deliveries += 1 }, isCurrent: { _ in current })
    let upgrade = AppUpgrade.installed(build: 334, axodBuild: 81, version: "0.63")
    await notifier.notify(upgrade, running: 333)
    XCTAssertEqual(deliveries, 0)
    XCTAssertEqual(store.integer(forKey: AppUpgradeNotificationRoute.lastNotifiedKey), 0)
    allowed = true
    current = false
    await notifier.notify(upgrade, running: 333)
    XCTAssertEqual(deliveries, 0)
    current = true
    await notifier.notify(upgrade, running: 334)
    XCTAssertEqual(deliveries, 0, "never notify about the running or an older build")
    await notifier.notify(upgrade, running: 333)
    XCTAssertEqual(deliveries, 1)
  }

  @MainActor
  func testFailedDeliveryCanRetry() async {
    struct Failed: Error {}
    let store = defaults()
    var failing = true
    var deliveries = 0
    let notifier = AppUpgradeNotifications(defaults: store, authorize: { true },
      deliver: { _ in if failing { throw Failed() }; deliveries += 1 }, isCurrent: { _ in true })
    let upgrade = AppUpgrade.installed(build: 334, axodBuild: 81, version: "0.63")
    await notifier.notify(upgrade, running: 333)
    XCTAssertEqual(store.integer(forKey: AppUpgradeNotificationRoute.lastNotifiedKey), 0)
    failing = false
    await notifier.notify(upgrade, running: 333)
    XCTAssertEqual(deliveries, 1)
  }

  @MainActor
  func testRepeatedChecksDuringAuthorizationCannotQueueDuplicateBanners() async {
    var authorization: CheckedContinuation<Bool, Never>?
    var deliveries = 0
    let notifier = AppUpgradeNotifications(defaults: defaults(),
      authorize: { await withCheckedContinuation { authorization = $0 } },
      deliver: { _ in deliveries += 1 }, isCurrent: { _ in true })
    let upgrade = AppUpgrade.installed(build: 334, axodBuild: 81, version: "0.63")
    let first = Task { await notifier.notify(upgrade, running: 333) }
    while authorization == nil { await Task.yield() }
    await notifier.notify(upgrade, running: 333)
    authorization?.resume(returning: true)
    await first.value
    XCTAssertEqual(deliveries, 1)
  }

  func testOnlyExplicitUpgradeActionUpgradesAndTerminalContentCannotRouteIt() {
    let route = AppUpgradeNotificationRoute.self
    XCTAssertEqual(route.action(category: route.category, identifier: route.upgradeAction), .upgrade)
    XCTAssertEqual(route.action(category: route.category, identifier: UNNotificationDefaultActionIdentifier), .offer)
    XCTAssertEqual(route.action(category: route.category, identifier: UNNotificationDismissActionIdentifier), .ignore)
    XCTAssertEqual(route.action(category: "", identifier: route.upgradeAction), .ignore)
    XCTAssertEqual(route.action(category: "terminal", identifier: UNNotificationDefaultActionIdentifier), .ignore)
  }
}
