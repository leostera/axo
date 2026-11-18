import AxoDaemonManager
import Foundation

/// When the launch splash and the terminal window trade places.
///
/// The terminal window only ever shows a fully operational Axod: running, with this run's
/// Session catalog live. Until then (launching, updating, restarting, or after Axod goes away)
/// only the splash shows, however long that takes, and it stays up long enough not to flash.
/// When Axod can't start without the person, the splash says why and offers the fix.
enum LaunchSplashGate {
  /// Shorter than this reads as a flicker.
  static let minimumShown: Duration = .milliseconds(900)

  /// How long the catalog may be down while Axod is still reported running before the terminal
  /// gives way to the splash: long enough for one failed request to recover on its first retry
  /// (`TerminalCatalogSync` retries after 250 ms), short of the restart that follows a real outage.
  static let catalogOutageGrace: Duration = .milliseconds(1500)

  /// Whether the terminal window may show.
  static func isOperational(daemonRunning: Bool, catalogLive: Bool) -> Bool {
    daemonRunning && catalogLive
  }

  /// What the terminal window does about Axod's state.
  enum TerminalHold: Equatable {
    /// Axod is operational: show it.
    case show
    /// Axod isn't running (starting, updating, restarting, failed): the splash, now.
    case holdNow
    /// Axod is reported running but its catalog is down: the splash, unless the catalog is back
    /// within `catalogOutageGrace`.
    case holdAfterGrace
  }

  static func terminalHold(daemonRunning: Bool, catalogLive: Bool) -> TerminalHold {
    if !daemonRunning { return .holdNow }
    return catalogLive ? .show : .holdAfterGrace
  }

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
    /// A newer axod than this Axo's runs; replacing it stops every terminal, so only on request.
    case newerDaemonRunning(running: UInt64)

    var message: String {
      switch self {
      case .approveInLoginItems: "axod needs your approval in Login Items."
      case .turnOn: "axod is turned off."
      case .retry(let reason): "axod couldn’t start: \(reason)"
      case .newerDaemonRunning(let running):
        "A newer axod (build \(running)) is running. Open the newer Axo, or restart axod with this older one, which stops every terminal and Pi process."
      }
    }

    var actionTitle: String {
      switch self {
      case .approveInLoginItems: "Open Login Items"
      case .turnOn: "Turn On axod"
      case .retry: "Try Again"
      case .newerDaemonRunning: "Restart axod with This Axo"
      }
    }
  }

  static func attention(for status: DaemonController.Status) -> Attention? {
    switch status {
    case .requiresApproval: .approveInLoginItems
    case .disabled: .turnOn
    case .failed(let reason): .retry(reason: reason)
    case .newerDaemonRunning(let running, _): .newerDaemonRunning(running: running)
    case .starting, .running, .updating: nil
    }
  }
}
