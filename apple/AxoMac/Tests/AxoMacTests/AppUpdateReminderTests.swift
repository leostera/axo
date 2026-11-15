import AxoDaemonManager
import XCTest
@testable import AxoMac

final class AppUpdateReminderTests: XCTestCase {
  private func store() -> UserDefaults {
    let name = "axo-update-reminder-test-\(UUID())"
    let store = UserDefaults(suiteName: name)!
    addTeardownBlock { store.removePersistentDomain(forName: name) }
    return store
  }

  func testSkipOnlyAffectsThatVersionAndReminderIsOnceAfterItsDeadline() {
    let defaults = store()
    let now = Date(timeIntervalSince1970: 1_000_000)
    AppUpdateReminder.skip(build: 342, defaults: defaults)
    XCTAssertFalse(AppUpdateReminder.mayNotify(build: 342, defaults: defaults, now: now))
    XCTAssertTrue(AppUpdateReminder.mayNotify(build: 343, defaults: defaults, now: now))
    AppUpdateReminder.remind(build: 342, defaults: defaults, now: now)
    XCTAssertFalse(AppUpdateReminder.mayNotify(build: 342, defaults: defaults, now: now))
    let due = now.addingTimeInterval(AppUpdateReminder.delay)
    XCTAssertTrue(AppUpdateReminder.mayNotify(build: 342, defaults: defaults, now: due))
    AppUpdateReminder.delivered(build: 342, defaults: defaults)
    XCTAssertFalse(AppUpdateReminder.mayNotify(build: 342, defaults: defaults, now: due))
    // An explicit later reminder can repeat a previously-delivered banner once.
    AppUpdateReminder.remind(build: 342, defaults: defaults, now: due)
    XCTAssertTrue(AppUpdateReminder.mayNotify(build: 342, defaults: defaults, now: due.addingTimeInterval(AppUpdateReminder.delay)))
    AppUpdateReminder.delivered(build: 343, defaults: defaults)
    XCTAssertFalse(AppUpdateReminder.mayNotify(build: 342, defaults: defaults, now: Date.distantFuture))
    XCTAssertEqual(defaults.integer(forKey: AppUpgradeNotificationRoute.lastNotifiedKey), 343)
  }

  @MainActor
  func testNotifierHonorsSkipAndSnoozeWithoutAskingAuthorizationAndKeepsManualModelIndependent() async {
    let defaults = store()
    let start = Date(timeIntervalSince1970: 1_000_000)
    var now = start
    var authorizations = 0
    var deliveries = 0
    let notifier = AppUpgradeNotifications(defaults: defaults,
      authorize: { authorizations += 1; return true }, deliver: { _ in deliveries += 1 },
      isCurrent: { _ in true }, now: { now })
    let upgrade = AppUpgrade.installed(build: 342, axodBuild: 83, version: "0.71")
    AppUpdateReminder.skip(build: 342, defaults: defaults)
    await notifier.notify(upgrade, running: 341)
    XCTAssertEqual(authorizations, 0)
    AppUpdateReminder.remind(build: 342, defaults: defaults, now: now)
    await notifier.notify(upgrade, running: 341)
    XCTAssertEqual(authorizations, 0)
    now = start.addingTimeInterval(AppUpdateReminder.delay)
    await notifier.notify(upgrade, running: 341)
    await notifier.notify(upgrade, running: 341)
    XCTAssertEqual(deliveries, 1)
    XCTAssertEqual(authorizations, 1)
    // Presentation has no skip preference: an explicit manual check can always show the release.
    let manual = AppUpdatePresentation(runningVersion: "0.70", runningAxod: 82)
    AppUpdateReminder.skip(build: 342, defaults: defaults)
    manual.state = .available(upgrade)
    XCTAssertEqual(manual.title, "Axo 0.71 is available")
  }
}
