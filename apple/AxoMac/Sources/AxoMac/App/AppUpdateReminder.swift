import Foundation

/// Manual checks ignore these preferences. They only control automatic update banners.
enum AppUpdateReminder {
  static let skippedBuildKey = "upgrade.skippedBuild.v1"
  static let reminderBuildKey = "upgrade.reminderBuild.v1"
  static let reminderDateKey = "upgrade.reminderAfter.v1"
  static let delay: TimeInterval = 24 * 60 * 60

  static func skip(build: Int, defaults: UserDefaults) {
    defaults.set(build, forKey: skippedBuildKey)
    if defaults.integer(forKey: reminderBuildKey) == build { clearReminder(defaults) }
  }
  static func remind(build: Int, defaults: UserDefaults, now: Date) {
    if defaults.integer(forKey: skippedBuildKey) == build { defaults.removeObject(forKey: skippedBuildKey) }
    defaults.set(build, forKey: reminderBuildKey)
    defaults.set(now.addingTimeInterval(delay).timeIntervalSince1970, forKey: reminderDateKey)
  }
  static func mayNotify(build: Int, defaults: UserDefaults, now: Date) -> Bool {
    guard defaults.integer(forKey: skippedBuildKey) != build,
      build >= defaults.integer(forKey: AppUpgradeNotificationRoute.lastNotifiedKey) else { return false }
    if defaults.integer(forKey: reminderBuildKey) == build {
      let due = defaults.double(forKey: reminderDateKey)
      if due.isFinite, due > 0 { return now.timeIntervalSince1970 >= due }
    }
    return build > defaults.integer(forKey: AppUpgradeNotificationRoute.lastNotifiedKey)
  }
  static func delivered(build: Int, defaults: UserDefaults) {
    let key = AppUpgradeNotificationRoute.lastNotifiedKey
    defaults.set(max(build, defaults.integer(forKey: key)), forKey: key)
    if defaults.integer(forKey: reminderBuildKey) <= build { clearReminder(defaults) }
  }
  private static func clearReminder(_ defaults: UserDefaults) {
    defaults.removeObject(forKey: reminderBuildKey)
    defaults.removeObject(forKey: reminderDateKey)
  }
}
