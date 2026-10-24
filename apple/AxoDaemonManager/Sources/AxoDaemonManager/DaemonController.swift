import AxoRPC
import Foundation
import Observation
import OSLog
import ServiceManagement

@MainActor
@Observable
public final class DaemonController {
  public enum Status: Equatable {
    case starting
    case running(version: String, buildNumber: BuildNumber)
    case updating
    case requiresApproval
    case disabled
    case failed(String)

    public var isRunning: Bool {
      if case .running = self { true } else { false }
    }

    public var menuTitle: String {
      switch self {
      case .starting: "axod: Starting…"
      case .running: "axod: Running"
      case .updating: "axod: Updating…"
      case .requiresApproval: "axod: Needs Approval"
      case .disabled: "axod: Disabled"
      case .failed: "axod: Unavailable"
      }
    }

    public var settingsTitle: String {
      switch self {
      case .starting: "Starting…"
      case .running(_, let buildNumber): "Running (build \(buildNumber))"
      case .updating: "Restarting for this app build…"
      case .requiresApproval: "Approval required in Login Items settings"
      case .disabled: "Not enabled"
      case .failed(let message): "Unavailable — \(message)"
      }
    }
  }

  public private(set) var status: Status = .starting

  private static let servicePlistName = "dev.leostera.axo.axod.plist"
  // Launchd can take longer than a health-check window to restore active PTYs and Pi bridges.
  private static let daemonStartupTimeout: Duration = .seconds(30)
  private static let healthPollInterval: Duration = .milliseconds(50)

  private let service = SMAppService.agent(plistName: servicePlistName)
  private let logger = Logger(subsystem: "dev.leostera.axo", category: "daemon")
  @ObservationIgnored private var startTask: Task<Void, Never>?

  @ObservationIgnored private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Publishes only real transitions; observers (menu bar, workbench) re-render on each publish.
  private func setStatus(_ newStatus: Status) {
    if status != newStatus { status = newStatus }
  }

  public static var appBuildNumberLabel: String {
    BuildNumber(bundleValue: Bundle.main.infoDictionary?["CFBundleVersion"])?.description
      ?? "Unknown"
  }

  public static func socketPath() throws -> UnixSocketPath {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Axo/run/axod.sock")
    return try UnixSocketPath(path.path)
  }

  private func makeSocketPath() throws -> UnixSocketPath {
    try Self.socketPath()
  }

  public func startIfNeeded() {
    logger.info("event=daemon.start_requested")
    guard startTask == nil else { return }
    startTask = Task {
      defer { startTask = nil }
      await start()
    }
  }

  public func enableDaemon() {
    guard startTask == nil else { return }
    startTask = Task {
      defer { startTask = nil }
      await registerFromExplicitUserAction()
    }
  }

  /// Re-verifies a daemon the app believed was running, e.g. after the catalog stream failed.
  /// A healthy probe changes nothing; otherwise the normal start path runs, which never restarts
  /// a slow daemon on its own.
  public func checkHealth() {
    guard startTask == nil, status.isRunning else { return }
    startTask = Task {
      defer { startTask = nil }
      if let socketPath = try? makeSocketPath(),
        (try? await UnixSocketRPC.health(at: socketPath)) != nil
      {
        return
      }
      logger.warning("event=daemon.health_recheck_failed")
      await start()
    }
  }

  /// Explicit user action only: restarts the LaunchAgent, which terminates the daemon's shells.
  public func restartDaemon() {
    guard startTask == nil else { return }
    startTask = Task {
      defer { startTask = nil }
      setStatus(.updating)
      do {
        let appBuildNumber = try makeAppBuildNumber()
        guard
          let daemon = try await restartDaemon(at: try makeSocketPath(), expectedBuild: appBuildNumber)
        else { return }
        setStatus(.running(version: daemon.version ?? "Unknown", buildNumber: appBuildNumber))
      } catch {
        setStatus(.failed(error.localizedDescription))
      }
    }
  }

  public func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private func start() async {
    setStatus(.starting)
    do {
      guard try ensureRegistered() else { return }
      try await checkBuildAndRestartIfNeeded()
    } catch {
      logger.error(
        "event=daemon.start_failed reason=\(error.localizedDescription, privacy: .private)")
      setStatus(.failed(error.localizedDescription))
    }
  }

  private func ensureRegistered() throws -> Bool {
    let serviceStatus = service.status
    logger.info(
      "event=daemon.service_status value=\(Self.serviceStatusName(serviceStatus), privacy: .public)"
    )
    let decision = RegistrationDecision.resolve(
      serviceStatus: serviceStatus,
      registrationIntentRecorded: defaults.bool(forKey: DaemonPreferenceKey.registrationRequested)
    )
    switch decision {
    case .alreadyEnabled:
      defaults.set(true, forKey: DaemonPreferenceKey.registrationSucceeded)
      return true
    case .approvalRequired:
      setStatus(.requiresApproval)
      return false
    case .missingService:
      throw DaemonControllerError.missingServiceDefinition
    case .userDisabled:
      setStatus(.disabled)
      return false
    case .registerOnce:
      logger.info("event=daemon.registration_started")
      defaults.set(true, forKey: DaemonPreferenceKey.registrationRequested)
      do {
        try service.register()
      } catch {
        if service.status == .requiresApproval {
          setStatus(.requiresApproval)
          return false
        }
        throw error
      }
      logger.info("event=daemon.registration_returned")
      return try recordRegistrationResult()
    case .unknown:
      throw DaemonControllerError.unknownServiceStatus
    }
  }

  private func registerFromExplicitUserAction() async {
    setStatus(.starting)
    do {
      switch service.status {
      case .enabled:
        defaults.set(true, forKey: DaemonPreferenceKey.registrationSucceeded)
        try await checkBuildAndRestartIfNeeded()
      case .requiresApproval:
        setStatus(.requiresApproval)
      case .notFound:
        throw DaemonControllerError.missingServiceDefinition
      case .notRegistered:
        defaults.set(true, forKey: DaemonPreferenceKey.registrationRequested)
        do {
          try service.register()
        } catch {
          if service.status == .requiresApproval {
            setStatus(.requiresApproval)
            return
          }
          throw error
        }
        guard try recordRegistrationResult() else { return }
        try await checkBuildAndRestartIfNeeded()
      @unknown default:
        throw DaemonControllerError.unknownServiceStatus
      }
    } catch {
      setStatus(.failed(error.localizedDescription))
    }
  }

  private func recordRegistrationResult() throws -> Bool {
    switch service.status {
    case .enabled:
      defaults.set(true, forKey: DaemonPreferenceKey.registrationSucceeded)
      return true
    case .requiresApproval:
      setStatus(.requiresApproval)
      return false
    case .notRegistered:
      if defaults.bool(forKey: DaemonPreferenceKey.registrationSucceeded) {
        setStatus(.disabled)
        return false
      }
      throw DaemonControllerError.registrationDidNotComplete
    case .notFound:
      throw DaemonControllerError.missingServiceDefinition
    @unknown default:
      throw DaemonControllerError.unknownServiceStatus
    }
  }

  private func checkBuildAndRestartIfNeeded() async throws {
    let socketPath = try makeSocketPath()
    let appBuildNumber = try makeAppBuildNumber()
    logger.info("event=daemon.health_check_started")

    // A slow daemon may be recovering many Sessions; restarting it would kill their shells.
    // Timeouts surface as `.failed` and only an explicit user action restarts the LaunchAgent.
    let daemon = try await waitForDaemon(at: socketPath, expectedBuild: nil)

    logger.info("event=daemon.health_check_succeeded build=\(daemon.buildNumber, privacy: .public)")
    guard daemon.buildNumber != appBuildNumber.value else {
      setStatus(.running(version: daemon.version ?? "Unknown", buildNumber: appBuildNumber))
      return
    }

    setStatus(.updating)
    guard
      let restartedDaemon =
        try await restartDaemon(at: socketPath, expectedBuild: appBuildNumber)
    else { return }
    setStatus(.running(version: restartedDaemon.version ?? "Unknown", buildNumber: appBuildNumber))
  }

  private func restartDaemon(
    at socketPath: UnixSocketPath,
    expectedBuild: BuildNumber
  ) async throws -> DaemonHealth? {
    logger.info("event=daemon.restart_started")
    try await service.unregister()
    do {
      try service.register()
    } catch {
      if service.status == .requiresApproval {
        logger.warning("event=daemon.restart_requires_approval")
        setStatus(.requiresApproval)
        return nil
      }
      throw error
    }
    guard try recordRegistrationResult() else { return nil }

    logger.info("event=daemon.restart_registered")
    let daemon = try await waitForDaemon(at: socketPath, expectedBuild: expectedBuild)
    logger.info("event=daemon.restart_succeeded")
    return daemon
  }

  private func makeAppBuildNumber() throws -> BuildNumber {
    guard
      let buildNumber = BuildNumber(
        bundleValue: Bundle.main.infoDictionary?["CFBundleVersion"]
      )
    else {
      throw DaemonControllerError.invalidAppBuild
    }
    return buildNumber
  }

  private func waitForDaemon(
    at socketPath: UnixSocketPath,
    expectedBuild: BuildNumber?
  ) async throws -> DaemonHealth {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: Self.daemonStartupTimeout)
    while clock.now < deadline {
      do {
        let health = try await UnixSocketRPC.health(at: socketPath)
        if let expectedBuild, health.buildNumber != expectedBuild.value {
          try await Task.sleep(for: Self.healthPollInterval)
          continue
        }
        return health
      } catch let error as UnixSocketRPCError {
        switch error {
        case .connectionFailed, .requestTimedOut:
          break
        case .invalidSocketPath, .invalidResponse, .serverRejected:
          throw error
        }
      }
      try await Task.sleep(for: Self.healthPollInterval)
    }

    if let expectedBuild {
      throw DaemonControllerError.restartTimedOut(expectedBuild)
    }
    throw DaemonControllerError.startupTimedOut
  }

  private static func serviceStatusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: "enabled"
    case .requiresApproval: "requires-approval"
    case .notFound: "not-found"
    case .notRegistered: "not-registered"
    @unknown default: "unknown"
    }
  }
}

private enum DaemonControllerError: Error, LocalizedError {
  case invalidAppBuild
  case missingServiceDefinition
  case registrationDidNotComplete
  case restartTimedOut(BuildNumber)
  case startupTimedOut
  case unknownServiceStatus

  var errorDescription: String? {
    switch self {
    case .invalidAppBuild:
      "the app bundle has no valid numeric build number"
    case .missingServiceDefinition:
      "the bundled axod LaunchAgent definition is missing"
    case .registrationDidNotComplete:
      "axod did not register; check Login Items settings"
    case .restartTimedOut(let buildNumber):
      "axod did not restart with build \(buildNumber)"
    case .startupTimedOut:
      "axod did not become ready; it may still be recovering Sessions"
    case .unknownServiceStatus:
      "macOS returned an unknown axod service status"
    }
  }
}
