import AxoRPC
import Foundation
import XCTest

@testable import AxoMac

@MainActor
final class AgentAutoRestartPreferenceTests: XCTestCase {
  func testAutomaticPiRestartPreferencePersistsAcrossModelInstances() throws {
    let suiteName = "axo-agent-auto-restart-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let socketPath = try UnixSocketPath("/tmp/axo-agent-auto-restart.sock")

    let firstModel = TerminalSessionsModel(
      socketPath: socketPath,
      selectedSessionDefaults: defaults
    )
    XCTAssertFalse(firstModel.automaticallyRestartUnavailablePi)

    firstModel.setAutomaticPiRestartEnabled(true)
    XCTAssertTrue(defaults.bool(forKey: "agent.autoRestartUnavailablePi.v1"))

    let reopenedModel = TerminalSessionsModel(
      socketPath: socketPath,
      selectedSessionDefaults: defaults
    )
    XCTAssertTrue(reopenedModel.automaticallyRestartUnavailablePi)

    reopenedModel.setAutomaticPiRestartEnabled(false)
    XCTAssertFalse(defaults.bool(forKey: "agent.autoRestartUnavailablePi.v1"))
  }
}
