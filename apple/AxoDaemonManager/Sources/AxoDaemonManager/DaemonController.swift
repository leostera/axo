import AxoRPC
import Combine
import Foundation
import OSLog
import ServiceManagement

@MainActor
public final class DaemonController: ObservableObject {
  public enum Status: Equatable {
    case starting
    case running(buildNumber: BuildNumber)
    case updating
    case requiresApproval
    case disabled
    case failed(String)

    public var menuTitle: String {
      switch self {
      case .starting: "Axo D: Starting…"
      case .running: "Axo D: Running"
      case .updating: "Axo D: Updating…"
      case .requiresApproval: "Axo D: Needs Approval"
      case .disabled: "Axo D: Disabled"
      case .failed: "Axo D: Unavailable"
      }
    }

    public var settingsTitle: String {
      switch self {
      case .starting: "Starting…"
      case .running(let buildNumber): "Running (build \(buildNumber))"
      case .updating: "Restarting for this app build…"
      case .requiresApproval: "Approval required in Login Items settings"
      case .disabled: "Not enabled"
      case .failed(let message): "Unavailable — \(message)"
      }
    }
  }

  @Published public private(set) var status: Status = .starting

  private static let registrationIntentKey = "dev.leostera.axo.axod.registrationRequested"
  private static let registrationReceiptKey = "dev.leostera.axo.axod.registrationSucceeded"
  private static let servicePlistName = "dev.leostera.axo.axod.plist"

  private let service = SMAppService.agent(plistName: servicePlistName)
  private let logger = Logger(subsystem: "dev.leostera.axo", category: "daemon")
  private var startTask: Task<Void, Never>?

  public init() {}

  public static var appBuildNumberLabel: String {
    BuildNumber(bundleValue: Bundle.main.infoDictionary?["CFBundleVersion"])?.description
      ?? "Unknown"
  }

  private func makeSocketPath() throws -> UnixSocketPath {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Axo/run/axod.sock")
    return try UnixSocketPath(path.path)
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

  public func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private func start() async {
    status = .starting
    do {
      guard try ensureRegistered() else { return }
      try await checkBuildAndRestartIfNeeded()
    } catch {
      logger.error(
        "event=daemon.start_failed reason=\(error.localizedDescription, privacy: .private)")
      status = .failed(error.localizedDescription)
    }
  }

  private func ensureRegistered() throws -> Bool {
    let serviceStatus = service.status
    logger.info(
      "event=daemon.service_status value=\(Self.serviceStatusName(serviceStatus), privacy: .public)"
    )
    let decision = RegistrationDecision.resolve(
      serviceStatus: serviceStatus,
      registrationIntentRecorded: UserDefaults.standard.bool(forKey: Self.registrationIntentKey)
    )
    switch decision {
    case .alreadyEnabled:
      UserDefaults.standard.set(true, forKey: Self.registrationReceiptKey)
      return true
    case .approvalRequired:
      status = .requiresApproval
      return false
    case .missingService:
      throw DaemonControllerError.missingServiceDefinition
    case .userDisabled:
      status = .disabled
      return false
    case .registerOnce:
      logger.info("event=daemon.registration_started")
      UserDefaults.standard.set(true, forKey: Self.registrationIntentKey)
      do {
        try service.register()
      } catch {
        if service.status == .requiresApproval {
          status = .requiresApproval
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
    status = .starting
    do {
      switch service.status {
      case .enabled:
        UserDefaults.standard.set(true, forKey: Self.registrationReceiptKey)
        try await checkBuildAndRestartIfNeeded()
      case .requiresApproval:
        status = .requiresApproval
      case .notFound:
        throw DaemonControllerError.missingServiceDefinition
      case .notRegistered:
        UserDefaults.standard.set(true, forKey: Self.registrationIntentKey)
        do {
          try service.register()
        } catch {
          if service.status == .requiresApproval {
            status = .requiresApproval
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
      status = .failed(error.localizedDescription)
    }
  }

  private func recordRegistrationResult() throws -> Bool {
    switch service.status {
    case .enabled:
      UserDefaults.standard.set(true, forKey: Self.registrationReceiptKey)
      return true
    case .requiresApproval:
      status = .requiresApproval
      return false
    case .notRegistered:
      if UserDefaults.standard.bool(forKey: Self.registrationReceiptKey) {
        status = .disabled
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
    let daemon = try await waitForDaemon(at: socketPath, expectedBuild: nil)
    logger.info("event=daemon.health_check_succeeded build=\(daemon.buildNumber, privacy: .public)")
    guard daemon.buildNumber != appBuildNumber.value else {
      status = .running(buildNumber: appBuildNumber)
      return
    }

    status = .updating
    try await service.unregister()
    do {
      try service.register()
    } catch {
      if service.status == .requiresApproval {
        status = .requiresApproval
        return
      }
      throw error
    }
    guard try recordRegistrationResult() else { return }
    _ = try await waitForDaemon(at: socketPath, expectedBuild: appBuildNumber)
    status = .running(buildNumber: appBuildNumber)
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
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      do {
        let health = try await UnixSocketRPC.health(at: socketPath)
        if let expectedBuild, health.buildNumber != expectedBuild.value {
          try await Task.sleep(nanoseconds: 50_000_000)
          continue
        }
        return health
      } catch let error as UnixSocketRPCError {
        switch error {
        case .connectionFailed, .requestTimedOut:
          break
        case .invalidSocketPath, .invalidResponse:
          throw error
        }
      }
      try await Task.sleep(nanoseconds: 50_000_000)
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
      "the bundled Axo D LaunchAgent definition is missing"
    case .registrationDidNotComplete:
      "Axo D did not register; check Login Items settings"
    case .restartTimedOut(let buildNumber):
      "Axo D did not restart with build \(buildNumber)"
    case .startupTimedOut:
      "Axo D did not become ready"
    case .unknownServiceStatus:
      "macOS returned an unknown Axo D service status"
    }
  }
}
