import AxoDaemonManager
import Foundation

/// When the launch splash gives way to the terminal window.
///
/// The terminal window only ever shows a live Axod: the splash stays up until Axod is running
/// and the Session catalog is live, however long that takes, and it stays up long enough not to
/// flash. When Axod can't start without the person, the splash says why and offers the fix.
enum LaunchSplashGate {
  /// Shorter than this reads as a flicker.
  static let minimumShown: Duration = .milliseconds(900)

  /// How far along launch is, for the progress bar: Axod starting, Axod up, the catalog live.
  static func progress(daemonRunning: Bool, catalogLive: Bool) -> Double {
    switch (daemonRunning, catalogLive) {
    case (_, true) where daemonRunning: 1
    case (true, _): 0.65
    default: 0.25
    }
  }

  static func shouldReveal(ready: Bool, elapsed: Duration) -> Bool {
    ready && elapsed >= minimumShown
  }

  /// What the person has to do before Axod can start, shown under the progress bar.
  enum Attention: Equatable {
    case approveInLoginItems
    case turnOn
    case retry(reason: String)

    var message: String {
      switch self {
      case .approveInLoginItems: "axod needs your approval in Login Items."
      case .turnOn: "axod is turned off."
      case .retry(let reason): "axod couldn’t start: \(reason)"
      }
    }

    var actionTitle: String {
      switch self {
      case .approveInLoginItems: "Open Login Items"
      case .turnOn: "Turn On axod"
      case .retry: "Try Again"
      }
    }
  }

  static func attention(for status: DaemonController.Status) -> Attention? {
    switch status {
    case .requiresApproval: .approveInLoginItems
    case .disabled: .turnOn
    case .failed(let reason): .retry(reason: reason)
    case .starting, .running, .updating: nil
    }
  }
}
