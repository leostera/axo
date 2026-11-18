import AxoClient
import AxoProtocol
import Foundation
import ServiceManagement
import XCTest

@testable import AxoDaemonManager

/// `DaemonController`'s start-up decisions against a fake macOS: which axod it keeps, and when it
/// restarts one (which stops every terminal).
@MainActor
final class DaemonControllerTests: XCTestCase {
  private let bundled = BuildNumber(87)!
  private let definition = LaunchAgentDefinition(
    bundlePath: "/Applications/Axo.app", plistSHA256: "abc", programSigningIdentity: "TEAM:axod")
  private let otherCopy = LaunchAgentDefinition(
    bundlePath: "/Users/leo/Downloads/Axo.app", plistSHA256: "abc", programSigningIdentity: "TEAM:axod")

  private func controller(_ mac: FakeMac, registered: LaunchAgentDefinition?) -> DaemonController {
    let name = "dev.leostera.axo.daemon-controller-test.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
    let defaults = UserDefaults(suiteName: name)!
    if let registered { defaults.set(try! JSONEncoder().encode(registered), forKey: DaemonPreferenceKey.registeredDefinition) }
    return DaemonController(defaults: defaults, system: mac.system(bundled: bundled, definition: definition))
  }

  private func started(_ daemon: DaemonController) async throws -> DaemonController.Status {
    daemon.startIfNeeded()
    let deadline = ContinuousClock.now + .seconds(10)
    while [.starting, .updating].contains(daemon.status) {
      guard ContinuousClock.now < deadline else { XCTFail("never settled"); break }
      try await Task.sleep(for: .milliseconds(5))
    }
    return daemon.status
  }

  func testTheSameAxodIsUsedAsItIs() async throws {
    let mac = FakeMac(running: 87)
    let status = try await started(controller(mac, registered: definition))
    XCTAssertEqual(status, .running(version: "test", buildNumber: bundled))
    XCTAssertEqual(mac.restarts, 0)
  }

  func testAnOlderAxodIsRestartedIntoThisAppsBuild() async throws {
    let mac = FakeMac(running: 86)
    let status = try await started(controller(mac, registered: definition))
    XCTAssertEqual(status, .running(version: "test", buildNumber: bundled))
    XCTAssertEqual(mac.kickstarts, 1)
  }

  func testANewerAxodIsLeftRunning() async throws {
    let mac = FakeMac(running: 88)
    let status = try await started(controller(mac, registered: definition))
    XCTAssertEqual(status, .newerDaemonRunning(running: 88, bundled: bundled))
    XCTAssertEqual(mac.restarts, 0, "nothing stops the newer axod's terminals")
    XCTAssertEqual(mac.running, 88)
  }

  func testANewerAxodAnotherCopyRegisteredIsNotReplacedByThisOnesDefinition() async throws {
    let mac = FakeMac(running: 88)
    let status = try await started(controller(mac, registered: otherCopy))
    XCTAssertEqual(status, .newerDaemonRunning(running: 88, bundled: bundled))
    XCTAssertEqual(mac.restarts, 0)
  }

  func testAnotherCopysOlderOrMissingAxodIsReplacedByThisOnesDefinition() async throws {
    for running in [UInt64(86), nil] {
      let mac = FakeMac(running: running)
      let status = try await started(controller(mac, registered: otherCopy))
      XCTAssertEqual(status, .running(version: "test", buildNumber: bundled), "running \(String(describing: running))")
      XCTAssertEqual(mac.unregisters, 1)
      XCTAssertEqual(mac.registers, 1)
      XCTAssertEqual(mac.kickstarts, 0)
    }
  }

  func testOnlyTheExplicitRestartMovesANewerAxodBack() async throws {
    let mac = FakeMac(running: 88)
    let daemon = controller(mac, registered: definition)
    _ = try await started(daemon)
    daemon.restartDaemon()
    let deadline = ContinuousClock.now + .seconds(10)
    while !daemon.status.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(daemon.status, .running(version: "test", buildNumber: bundled))
    XCTAssertEqual(mac.running, 87)
  }
}

/// A Mac with one axod job: which build answers health checks, and what launchd was asked.
@MainActor
private final class FakeMac {
  /// The build of the axod that answers; `nil` when none does.
  var running: UInt64?
  var kickstarts = 0
  var registers = 0
  var unregisters = 0
  var restarts: Int { kickstarts + registers + unregisters }
  private var bundled: UInt64 = 0

  init(running: UInt64?) { self.running = running }

  func system(bundled: BuildNumber, definition: LaunchAgentDefinition) -> DaemonSystem {
    self.bundled = bundled.value
    return DaemonSystem(
      service: Service(mac: self),
      bundledDaemonBuild: { bundled },
      bundledDefinition: { definition },
      launchdState: { [unowned self] in
        LaunchdJobState(isLoaded: true, isRunning: self.running != nil, lastExitCode: nil)
      },
      kickstart: { [unowned self] in
        self.kickstarts += 1
        self.running = self.bundled
      },
      health: { [unowned self] _ in
        guard let build = self.running else { throw AxoClientError.connectionFailed("no axod") }
        return DaemonHealth(version: "test", buildNumber: build, status: "ok")
      })
  }

  /// Registering starts this app's axod; unregistering stops whatever ran.
  final class Service: LoginItemService {
    unowned let mac: FakeMac
    init(mac: FakeMac) { self.mac = mac }
    var status: SMAppService.Status { .enabled }
    func register() throws {
      MainActor.assumeIsolated {
        mac.registers += 1
        mac.running = mac.bundled
      }
    }
    func unregister() async throws {
      await MainActor.run {
        mac.unregisters += 1
        mac.running = nil
      }
    }
  }
}
