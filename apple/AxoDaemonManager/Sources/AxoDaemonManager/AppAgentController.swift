import AppKit
import Darwin
import Foundation
import OSLog
import ServiceManagement

/// Axo's own LaunchAgent, `dev.leostera.axo.app`: launchd starts Axo at login and again after a
/// crash or a kill, but not after Quit Axo (`KeepAlive = { SuccessfulExit = false }`).
///
/// The Axo the person opens never stays: it registers this bundle's agent, waits for launchd's
/// Axo and hands over to it, so the Axo that runs is always the one launchd brings back.
@MainActor
public final class AppAgentController {
  public static let label = "dev.leostera.axo.app"
  private static let plistName = "dev.leostera.axo.app.plist"
  private static let programPath = "Contents/MacOS/Axo"
  /// Asks launchd's Axo to bring its terminal window up.
  public static let showTerminalNotification = Notification.Name("dev.leostera.axo.showTerminal")
  /// Asks the Axos whose pids are in `userInfo["pids"]` to quit for good; see `replace`.
  public static let quitForReplacementNotification = Notification.Name(
    "dev.leostera.axo.quitForReplacement")
  /// The launch argument an outdated Axo passes to the newer one it opens, to be replaced
  /// without asking again.
  public static let replaceRunningArgument = "--replace-running"

  private static let showTerminalRequestLifetime: TimeInterval = 60
  private static let quitTimeout: TimeInterval = 5
  private static let agentStartTimeout: TimeInterval = 20
  private static let registerAttempts = 4
  private static let kickstartTimeout: TimeInterval = 5

  private let service = SMAppService.agent(plistName: plistName)
  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "dev.leostera.axo", category: "app-agent")

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Whether this process is the one launchd started for the agent.
  public static var isAgentJob: Bool {
    ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
  }

  // MARK: - Who is running

  public func currentInstance() -> AxoInstance {
    Self.instance(pid: getpid())
  }

  public func otherInstances() -> [AxoInstance] {
    guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
      .map { Self.instance(pid: $0.processIdentifier) }
  }

  /// Where a process's executable is now, which follows a bundle that was moved aside after it
  /// started, and that bundle's build as it is on disk.
  static func instance(pid: Int32) -> AxoInstance {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
      return AxoInstance(pid: pid, bundlePath: nil, build: nil)
    }
    let executable = URL(fileURLWithPath: String(cString: buffer))
    // <bundle>/Contents/MacOS/<executable>
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().standardizedFileURL
    return AxoInstance(pid: pid, bundlePath: bundle.path, build: installedBuild(of: bundle))
  }

  /// `CFBundleVersion` as it is on disk now, not as the process loaded it.
  public static func installedBuild(of bundle: URL) -> String? {
    let plist = bundle.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return info["CFBundleVersion"] as? String
  }

  // MARK: - Handing over

  /// Makes launchd's Axo run from this bundle and returns its pid. Stops `replacing` first; they
  /// exit successfully, so launchd does not bring them back.
  public func handOver(replacing: [AxoInstance]) throws -> Int32 {
    logger.info("event=app_agent.handover_started replacing=\(replacing.count, privacy: .public)")
    removeHandMadeAgent()
    if replacing.isEmpty, service.status == .enabled, registeredDefinition() == currentDefinition(),
      launchctl(["kickstart", target]) == 0,
      let pid = try? waitForAgentInstance(timeout: Self.kickstartTimeout)
    {
      // Registered from this very bundle, and after Quit Axo loaded but not running.
      logger.info("event=app_agent.handover_succeeded pid=\(pid, privacy: .public) via=kickstart")
      return pid
    }
    // Registered from another bundle, or from this path's earlier bundle that an install swapped
    // out and deleted (launchd follows the bundle, not the path, so it cannot spawn it): stop
    // launchd's Axo without it coming back and register this one.
    _ = launchctl(["bootout", target])
    stop(replacing)
    try register()
    let pid = try waitForAgentInstance(timeout: Self.agentStartTimeout)
    logger.info("event=app_agent.handover_succeeded pid=\(pid, privacy: .public)")
    return pid
  }

  /// Asks launchd's (or the running) Axo to bring its terminal window up: at once if it is
  /// running, and when it starts if it is not yet.
  public func requestShowTerminal() {
    defaults.set(Date().timeIntervalSince1970, forKey: DaemonPreferenceKey.showTerminalRequestedAt)
    defaults.synchronize()
    DistributedNotificationCenter.default().postNotificationName(
      Self.showTerminalNotification, object: nil, userInfo: nil, deliverImmediately: true)
  }

  /// For launchd's Axo as it starts: whether the Axo that handed over asked for the terminal
  /// window. Answers once.
  public func consumeShowTerminalRequest() -> Bool {
    let requestedAt = defaults.double(forKey: DaemonPreferenceKey.showTerminalRequestedAt)
    guard requestedAt > 0 else { return false }
    defaults.removeObject(forKey: DaemonPreferenceKey.showTerminalRequestedAt)
    return Date().timeIntervalSince1970 - requestedAt < Self.showTerminalRequestLifetime
  }

  public func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  // MARK: - Steps

  private var target: String { "gui/\(getuid())/\(Self.label)" }

  private func register() throws {
    // Unregistering first makes launchd load this bundle's plist even when the agent was
    // registered from another copy of Axo.
    try? service.unregister()
    // Right after unregistering, or after Background Task Management first sees the agent,
    // macOS can refuse to bootstrap it for a moment (smd: "Job is not allowed to bootstrap",
    // EPERM); it allows it shortly after.
    var attempt = 0
    while true {
      attempt += 1
      do {
        try service.register()
        break
      } catch {
        if service.status == .requiresApproval { throw AppAgentError.requiresApproval }
        logger.warning(
          "event=app_agent.register_failed attempt=\(attempt, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
        )
        guard attempt < Self.registerAttempts else {
          throw AppAgentError.registrationFailed(error.localizedDescription)
        }
        _ = waitUntil(timeout: Double(attempt)) { false }
      }
    }
    switch service.status {
    case .requiresApproval: throw AppAgentError.requiresApproval
    case .notRegistered: throw AppAgentError.registrationFailed("macOS did not register it")
    default: break
    }
    if let definition = currentDefinition(), let data = try? JSONEncoder().encode(definition) {
      defaults.set(data, forKey: DaemonPreferenceKey.appAgentRegisteredDefinition)
    }
    logger.info("event=app_agent.registered")
  }

  /// Asks each Axo to quit for good, then forces whichever is still there.
  private func stop(_ instances: [AxoInstance]) {
    guard !instances.isEmpty else { return }
    let pids = instances.map(\.pid)
    DistributedNotificationCenter.default().postNotificationName(
      Self.quitForReplacementNotification, object: nil,
      userInfo: ["pids": pids.map(NSNumber.init(value:))], deliverImmediately: true)
    let running = { pids.compactMap { NSRunningApplication(processIdentifier: $0) }
      .filter { !$0.isTerminated } }
    guard !waitUntil(timeout: Self.quitTimeout, { running().isEmpty }) else { return }
    for application in running() {
      logger.warning(
        "event=app_agent.force_terminate pid=\(application.processIdentifier, privacy: .public)")
      application.forceTerminate()
    }
    _ = waitUntil(timeout: Self.quitTimeout) { running().isEmpty }
  }

  private func waitForAgentInstance(timeout: TimeInterval) throws -> Int32 {
    var pid: Int32?
    let started = waitUntil(timeout: timeout) {
      guard let bundleID = Bundle.main.bundleIdentifier else { return false }
      pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first { $0.processIdentifier != getpid() && $0.isFinishedLaunching && !$0.isTerminated }?
        .processIdentifier
      return pid != nil
    }
    guard started, let pid else { throw AppAgentError.agentDidNotStart }
    return pid
  }

  /// A plist an earlier Axo setup put in ~/Library/LaunchAgents under the agent's label. Loaded
  /// from there, launchd would keep it instead of this bundle's, and bring it back every login.
  private func removeHandMadeAgent() {
    let plist = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(Self.plistName)")
    guard FileManager.default.fileExists(atPath: plist.path) else { return }
    _ = launchctl(["bootout", target])
    do {
      try FileManager.default.removeItem(at: plist)
      logger.info("event=app_agent.hand_made_agent_removed")
    } catch {
      logger.error(
        "event=app_agent.hand_made_agent_not_removed reason=\(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func currentDefinition() -> LaunchAgentDefinition? {
    LaunchAgentDefinition.current(
      bundle: .main, plistName: Self.plistName, programPath: Self.programPath)
  }

  private func registeredDefinition() -> LaunchAgentDefinition? {
    defaults.data(forKey: DaemonPreferenceKey.appAgentRegisteredDefinition)
      .flatMap { try? JSONDecoder().decode(LaunchAgentDefinition.self, from: $0) }
  }

  /// Runs before NSApplication does: polls while letting the run loop deliver
  /// NSRunningApplication's updates.
  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
  }

  @discardableResult
  private func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    } catch {
      return -1
    }
  }
}

public enum AppAgentError: Error, LocalizedError, Equatable {
  case requiresApproval
  case registrationFailed(String)
  case agentDidNotStart

  public var errorDescription: String? {
    switch self {
    case .requiresApproval:
      "Axo needs approval in System Settings › General › Login Items to start at login and come back after a crash."
    case .registrationFailed(let reason):
      "macOS could not register Axo to start at login: \(reason)"
    case .agentDidNotStart:
      "launchd did not start Axo."
    }
  }
}
