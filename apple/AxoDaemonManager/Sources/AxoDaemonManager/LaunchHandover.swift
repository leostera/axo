import Foundation

/// A running Axo.app process, as another Axo sees it.
public struct AxoInstance: Equatable, Sendable {
  public var pid: Int32
  /// The bundle its executable is in now. A bundle replaced on disk after the process started
  /// shows up where its old copy was moved (dist/.Axo.app.previous), not at the new one's path.
  /// `nil` when it cannot be read, e.g. the old copy was deleted.
  public var bundlePath: String?
  /// That bundle's `CFBundleVersion`, read from disk; `nil` when unreadable.
  public var build: String?

  public init(pid: Int32, bundlePath: String?, build: String?) {
    self.pid = pid
    self.bundlePath = bundlePath
    self.build = build
  }

  /// Whether it runs the same bundle, at the same build, as `other`.
  public func runsSameApp(as other: AxoInstance) -> Bool {
    bundlePath != nil && build != nil && bundlePath == other.bundlePath && build == other.build
  }
}

/// What an Axo does as it starts, before any window, so exactly one Axo runs and it is the one
/// launchd keeps alive (`dev.leostera.axo.app`): back at login and after a crash, not after
/// Quit Axo.
public enum LaunchHandover: Equatable {
  /// This is launchd's Axo (or handing over is not possible): carry on starting.
  case runHere
  /// This very app is already running: bring its terminal window up and exit.
  case showRunning(pid: Int32)
  /// Another build or bundle of Axo is running: stop it, register this bundle's agent, hand over
  /// to launchd's Axo and exit. `askFirst` is false when the running Axo asked for this itself.
  case replace([AxoInstance], askFirst: Bool)
  /// No Axo is running: start launchd's Axo from this bundle, hand over and exit.
  case startAgent

  public static func decide(
    isAgentJob: Bool,
    replaceRequested: Bool,
    current: AxoInstance,
    others: [AxoInstance]
  ) -> LaunchHandover {
    if isAgentJob { return .runHere }
    if others.isEmpty { return .startAgent }
    if !replaceRequested, others.allSatisfy({ $0.runsSameApp(as: current) }),
      let running = others.first
    {
      return .showRunning(pid: running.pid)
    }
    return .replace(others, askFirst: !replaceRequested)
  }
}
