import XCTest
@testable import AxoMac

final class CLICommandSetupTests: XCTestCase {
  @MainActor
  func testFirstLaunchOfferInstallsOnceAndInstallerReceiptOrDeclineSuppressesIt() async throws {
    let fixture = try CLICommandInstallationTests.Fixture()
    defer { fixture.clean() }
    let domain = "axo-cli-setup-tests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    XCTAssertEqual(AxoPreferenceKey.cliCommandSetupOffered, "cli.commandSetupOffered.v1")
    var prompts = 0
    var installs = 0
    let model = CLICommandInstallation(bundle: fixture.bundle, destination: fixture.destination) { source in
      installs += 1
      try fixture.link(to: source)
    }
    func offer(_ accepted: Bool) async {
      await CLICommandSetup.offer(installation: model, defaults: defaults, present: {
        prompts += 1
        return accepted
      }, showFailure: { XCTFail($0) })
    }
    // An installer attempt, even cancelled or opted out, is an already-handled choice.
    defaults.set(true, forKey: AxoPreferenceKey.cliCommandSetupOffered)
    await offer(true)
    XCTAssertEqual(prompts, 0)
    defaults.removeObject(forKey: AxoPreferenceKey.cliCommandSetupOffered)
    await offer(false)
    await offer(true)
    XCTAssertEqual(prompts, 1)
    XCTAssertEqual(installs, 0)
    // A new profile accepts the one-time offer.
    defaults.removeObject(forKey: AxoPreferenceKey.cliCommandSetupOffered)
    await offer(true)
    await offer(true)
    XCTAssertEqual(prompts, 2)
    XCTAssertEqual(installs, 1)
    XCTAssertEqual(model.status, .installed)
  }

  @MainActor
  func testInstalledAndForeignCommandsStayQuietWhileUnavailableCopyRetainsOffer() async throws {
    let fixture = try CLICommandInstallationTests.Fixture()
    defer { fixture.clean() }
    let domain = "axo-cli-setup-tests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let model = CLICommandInstallation(bundle: fixture.bundle, destination: fixture.destination) { _ in XCTFail("No install expected") }
    func offer(_ installation: CLICommandInstallation) async {
      await CLICommandSetup.offer(installation: installation, defaults: defaults,
        present: { XCTFail("No prompt expected"); return true }, showFailure: { XCTFail($0) })
    }
    let absent = CLICommandInstallation(bundle: fixture.root.appendingPathComponent("absent.app"), destination: fixture.destination) { _ in XCTFail("Unavailable") }
    await offer(absent)
    XCTAssertFalse(defaults.bool(forKey: AxoPreferenceKey.cliCommandSetupOffered))
    try fixture.link(to: model.source)
    await offer(model)
    XCTAssertTrue(defaults.bool(forKey: AxoPreferenceKey.cliCommandSetupOffered))
    defaults.removeObject(forKey: AxoPreferenceKey.cliCommandSetupOffered)
    try FileManager.default.removeItem(at: fixture.destination)
    try fixture.link(to: fixture.root.appendingPathComponent("foreign"))
    await offer(model)
    XCTAssertEqual(model.status, .conflict)
    XCTAssertTrue(defaults.bool(forKey: AxoPreferenceKey.cliCommandSetupOffered))
  }

  @MainActor
  func testFailedSetupExplainsSettingsFallbackWithoutReprompting() async throws {
    let fixture = try CLICommandInstallationTests.Fixture()
    defer { fixture.clean() }
    let domain = "axo-cli-setup-tests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let model = CLICommandInstallation(bundle: fixture.bundle, destination: fixture.destination) { _ in
      throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission declined"])
    }
    var failures: [String] = []
    await CLICommandSetup.offer(installation: model, defaults: defaults, present: { true }, showFailure: { failures.append($0) })
    XCTAssertEqual(failures, ["Permission declined"])
    await CLICommandSetup.offer(installation: model, defaults: defaults, present: { XCTFail("Only once"); return true }, showFailure: { XCTFail($0) })
    XCTAssertEqual(model.status, .missing)
  }
}
