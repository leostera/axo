import Foundation
import Observation

@MainActor
@Observable
final class SleepPreventionController {
  static let preferenceKey = AxoPreferenceKey.preventSystemSleep

  private(set) var isEnabled: Bool

  private let defaults: UserDefaults
  private let beginActivity: () -> NSObjectProtocol
  private let endActivity: (NSObjectProtocol) -> Void
  @ObservationIgnored private var activity: NSObjectProtocol?

  init(
    defaults: UserDefaults = .standard,
    beginActivity: @escaping () -> NSObjectProtocol = {
      ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled],
        reason: "Axo is configured to prevent idle system sleep."
      )
    },
    endActivity: @escaping (NSObjectProtocol) -> Void = {
      ProcessInfo.processInfo.endActivity($0)
    }
  ) {
    self.defaults = defaults
    self.beginActivity = beginActivity
    self.endActivity = endActivity
    isEnabled = defaults.bool(forKey: Self.preferenceKey)

    if isEnabled {
      activity = beginActivity()
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }

    defaults.set(enabled, forKey: Self.preferenceKey)
    isEnabled = enabled

    if enabled {
      activity = beginActivity()
    } else if let activity {
      endActivity(activity)
      self.activity = nil
    }
  }
}
