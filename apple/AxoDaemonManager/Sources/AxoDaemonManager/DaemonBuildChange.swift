import AxoProtocol

/// How the axod that answers compares with the one this app bundles, and so whether starting
/// this app may restart it. Restarting axod stops every terminal and Pi process, so it happens on
/// its own only to move forward.
public enum DaemonBuildChange: Equatable, Sendable {
  /// The same build: use it.
  case none
  /// This app bundles a newer axod: restart into it.
  case upgrade
  /// The running axod is newer than this app's, such as an older copy of Axo opened by mistake.
  /// It keeps running: an older axod would read state a newer one wrote, and only the person can
  /// choose that (`DaemonController.restartDaemon()`).
  case downgrade(running: UInt64)

  public static func between(running: UInt64, bundled: BuildNumber) -> DaemonBuildChange {
    if running == bundled.value { return .none }
    return running < bundled.value ? .upgrade : .downgrade(running: running)
  }
}
