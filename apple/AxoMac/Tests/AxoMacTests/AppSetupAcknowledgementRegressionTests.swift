import AxoProtocol
import XCTest

@testable import AxoMac

@MainActor
final class AppSetupAcknowledgementRegressionTests: XCTestCase {
  private func store() -> UserDefaults {
    let name = "axo-acknowledgement-regression-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
  }

  private func effects(check: @escaping () async -> SetupSnapshot) -> AppSetupEffects {
    AppSetupEffects(check: check, fix: { _ in XCTFail("No repair during observation") },
      connectionStatus: { XCTFail("No connection step"); throw CancellationError() },
      guide: { _, _, _ in XCTFail("No guide") }, openTerminal: { XCTFail("No terminal") },
      restartDaemon: { XCTFail("No restart") })
  }

  func testTransientUnknownDoesNotPretendAnAcknowledgedLimitationRecovered() async {
    var snapshot = AppSetupTests.snapshot(.notGranted)
    let defaults = store()
    let model = AppSetupModel(defaults: defaults, effects: effects(check: { snapshot }))
    await model.refresh()
    model.acknowledge()
    let acknowledged = defaults.stringArray(forKey: AxoPreferenceKey.setupAcknowledgedIssues)
    snapshot = AppSetupTests.snapshot(.unknown)
    await model.refresh()
    XCTAssertEqual(defaults.stringArray(forKey: AxoPreferenceKey.setupAcknowledgedIssues), acknowledged,
      "A failed probe is not evidence of recovered permissions")
    snapshot = AppSetupTests.snapshot(.notGranted)
    await model.refresh()
    XCTAssertFalse(model.shouldPresentAutomatically, "The same limitation was already acknowledged; no grant ever recovered")
  }

  func testOnlyTheActuallyRecoveredCheckLosesItsAcknowledgement() async {
    var snapshot = AppSetupTests.snapshot(.notGranted)
    let defaults = store()
    let model = AppSetupModel(defaults: defaults, effects: effects(check: { snapshot }))
    await model.refresh()
    model.acknowledge()
    let old = Set(defaults.stringArray(forKey: AxoPreferenceKey.setupAcknowledgedIssues) ?? [])
    snapshot.permissions = DaemonPermissions(processId: 42, accessibility: .notGranted, inputControl: .notGranted,
      screenRecording: .granted, developerTools: .notGranted, fullDiskAccess: .notGranted,
      automationFinder: .notGranted, automationSystemEvents: .notGranted)
    await model.refresh()
    let remaining = Set(defaults.stringArray(forKey: AxoPreferenceKey.setupAcknowledgedIssues) ?? [])
    XCTAssertEqual(remaining, old.filter { !$0.hasPrefix("screenRecording:") })
    snapshot = AppSetupTests.snapshot(.notGranted)
    await model.refresh()
    XCTAssertTrue(model.shouldPresentAutomatically, "A real recovered-then-revoked grant is a new issue")
  }
}
