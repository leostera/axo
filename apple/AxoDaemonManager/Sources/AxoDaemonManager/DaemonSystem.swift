import AxoClient
import AxoProtocol
import Foundation
import ServiceManagement

/// The login item launchd runs axod from: `SMAppService` in the app, a fake in tests.
protocol LoginItemService: AnyObject {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() async throws
}

extension SMAppService: LoginItemService {}

/// Everything `DaemonController` asks of macOS and axod, so its decisions can be tested without
/// either. `live` is the app's.
struct DaemonSystem {
  var service: any LoginItemService
  /// This bundle's `AXODBuildNumber`; `nil` when it is missing or not a build number.
  var bundledDaemonBuild: () -> BuildNumber?
  /// The definition this bundle would register; `nil` when its plist cannot be read.
  var bundledDefinition: () -> LaunchAgentDefinition?
  var launchdState: () async -> LaunchdJobState
  /// `launchctl kickstart -k`: restart the job in place from its registered definition.
  var kickstart: () async throws -> Void
  /// One health check over a fresh connection.
  var health: (UnixSocketPath) async throws -> DaemonHealth

  static let servicePlistName = "dev.leostera.axo.axod.plist"
  /// The plist's `Label`.
  static let serviceLabel = "dev.leostera.axo.axod"

  @MainActor static let live = DaemonSystem(
    service: SMAppService.agent(plistName: servicePlistName),
    bundledDaemonBuild: { BuildNumber(bundleValue: Bundle.main.infoDictionary?["AXODBuildNumber"]) },
    bundledDefinition: {
      LaunchAgentDefinition.current(bundle: .main, plistName: servicePlistName, programPath: "Contents/Helpers/axod")
    },
    launchdState: { await LaunchdJobState.read(label: serviceLabel) },
    kickstart: kickstartJob,
    health: { socketPath in
      try await AxodConnection.withFreshConnection(to: socketPath) { try await $0.health() }
    })

  private static func kickstartJob() async throws {
    let target = "gui/\(getuid())/\(serviceLabel)"
    let result: Result<Int32, Error> = await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["kickstart", "-k", target]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      return Result {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
      }
    }.value
    switch result {
    case .success(0):
      return
    case .success(let status):
      throw DaemonControllerError.kickstartFailed("launchctl exited with status \(status)")
    case .failure(let error):
      throw DaemonControllerError.kickstartFailed(error.localizedDescription)
    }
  }
}
