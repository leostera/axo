import Foundation

/// When the launch splash gives way to the terminal window.
///
/// It waits for Axod and the Session catalog, so the terminal opens ready rather than on a
/// "starting" placeholder; it stays up long enough not to flash, and gives way early when the
/// daemon needs the person (the terminal window explains) or when starting takes too long.
enum LaunchSplashGate {
  /// Shorter than this reads as a flicker.
  static let minimumShown: Duration = .milliseconds(900)
  /// After this the terminal opens anyway and shows whatever state Axod is in.
  static let patience: Duration = .seconds(12)

  /// How far along launch is, for the progress bar: Axod starting, Axod up, the catalog live.
  static func progress(daemonRunning: Bool, catalogLive: Bool) -> Double {
    switch (daemonRunning, catalogLive) {
    case (_, true) where daemonRunning: 1
    case (true, _): 0.65
    default: 0.25
    }
  }

  static func shouldReveal(ready: Bool, needsAttention: Bool, elapsed: Duration) -> Bool {
    if elapsed >= patience || needsAttention { return true }
    return ready && elapsed >= minimumShown
  }
}
