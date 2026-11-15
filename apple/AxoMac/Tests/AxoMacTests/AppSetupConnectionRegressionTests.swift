import AxoProtocol
import XCTest

@testable import AxoMac

@MainActor
final class AppSetupConnectionRegressionTests: XCTestCase {
  private func model(read: @escaping () async throws -> SetupConnectionStatus) -> AppSetupModel {
    let name = "axo-connection-regression-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    let effects = AppSetupEffects(check: { AppSetupTests.snapshot() },
      fix: { _ in XCTFail("A connection observation must not request a permission") },
      connectionStatus: read,
      guide: { _, _, _ in XCTFail("No System Settings handoff during a connection observation") },
      openTerminal: { XCTFail("Observations must not open terminals") },
      restartDaemon: { XCTFail("Observations must not restart axod") },
      openPairing: { XCTFail("Observations must not start pairing") })
    let model = AppSetupModel(defaults: defaults, effects: effects)
    model.next(); model.next()
    return model
  }

  func testConnectionFailureClearsEarlierSuccessAndCanRecover() async {
    var offline = false
    let model = model {
      if offline { throw URLError(.cannotConnectToHost) }
      return SetupConnectionStatus(health: AppSetupTests.snapshot().health!, account: .connected)
    }
    await model.refreshConnection()
    XCTAssertEqual(model.connection?.account, .connected)
    offline = true
    await model.refreshConnection()
    XCTAssertNil(model.connection, "A stopped daemon must not keep a stale connected badge")
    XCTAssertNotNil(model.connectionFailure)
    XCTAssertFalse(model.isCheckingConnection)
    offline = false
    await model.refreshConnection()
    XCTAssertEqual(model.connection?.account, .connected)
    XCTAssertNil(model.connectionFailure)
    XCTAssertFalse(model.isCheckingConnection)
  }

  func testUnknownAccountDoesNotEraseAHealthyLocalService() async {
    let model = model {
      SetupConnectionStatus(health: AppSetupTests.snapshot().health!, account: .unknown)
    }
    await model.refreshConnection()
    XCTAssertTrue(model.connection?.health.ready == true)
    XCTAssertEqual(model.connection?.account, .unknown)
    XCTAssertNil(model.connectionFailure)
    model.next()
    XCTAssertEqual(model.step, .ready, "A cloud outage must not gate local Sessions")
  }

  func testRestoringDaemonIsNeverReportedAsReady() async {
    let model = model {
      SetupConnectionStatus(health: DaemonHealth(version: "fixture", buildNumber: 83,
        status: "running", ready: false), account: .offline)
    }
    await model.refreshConnection()
    XCTAssertFalse(model.connection!.health.ready)
    XCTAssertEqual(model.connection?.account, .offline)
    XCTAssertNil(model.connectionFailure, "Restoration is not an unreachable daemon")
  }

  func testOverlappingRefreshesCoalesceAndLeavingRetiresFailure() async throws {
    var calls = 0
    var pending: CheckedContinuation<SetupConnectionStatus, Error>?
    let model = model {
      calls += 1
      return try await withCheckedThrowingContinuation { pending = $0 }
    }
    let first = Task { await model.refreshConnection() }
    let deadline = Date().addingTimeInterval(2)
    while pending == nil && Date() < deadline { await Task.yield() }
    let reply = try XCTUnwrap(pending)
    await model.refreshConnection()
    XCTAssertEqual(calls, 1, "A slow socket must not accumulate refresh work")
    XCTAssertTrue(model.isCheckingConnection)
    model.back()
    XCTAssertFalse(model.isCheckingConnection)
    reply.resume(throwing: URLError(.timedOut))
    await first.value
    XCTAssertNil(model.connectionFailure, "An old failure must not appear on the permission step")
    XCTAssertNil(model.connection)
  }
}
