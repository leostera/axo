import XCTest

@testable import AxoDaemonManager

final class LaunchHandoverTests: XCTestCase {
  private let current = AxoInstance(pid: 10, bundlePath: "/dist/Axo.app", build: "260")

  func testLaunchdsAxoAlwaysRuns() {
    let older = AxoInstance(pid: 9, bundlePath: "/dist/.Axo.app.previous", build: "259")
    XCTAssertEqual(
      LaunchHandover.decide(
        isAgentJob: true, replaceRequested: false, current: current, others: [older]),
      .runHere)
  }

  func testAnAxoOpenedWithNothingRunningStartsLaunchdsAxo() {
    XCTAssertEqual(
      LaunchHandover.decide(isAgentJob: false, replaceRequested: false, current: current, others: []),
      .startAgent)
  }

  func testOpeningTheRunningAxoShowsIt() {
    let running = AxoInstance(pid: 9, bundlePath: "/dist/Axo.app", build: "260")
    XCTAssertEqual(
      LaunchHandover.decide(
        isAgentJob: false, replaceRequested: false, current: current, others: [running]),
      .showRunning(pid: 9))
  }

  func testAnotherBuildIsReplacedAfterAsking() {
    // Swapped out by the install: the old process's executable now lives in the moved bundle.
    let older = AxoInstance(pid: 9, bundlePath: "/dist/.Axo.app.previous", build: "259")
    XCTAssertEqual(
      LaunchHandover.decide(
        isAgentJob: false, replaceRequested: false, current: current, others: [older]),
      .replace([older], askFirst: true))
  }

  func testAnotherCopyOfTheSameBuildIsReplacedToo() {
    let elsewhere = AxoInstance(pid: 9, bundlePath: "/Applications/Axo.app", build: "260")
    XCTAssertEqual(
      LaunchHandover.decide(
        isAgentJob: false, replaceRequested: false, current: current, others: [elsewhere]),
      .replace([elsewhere], askFirst: true))
  }

  func testAnAxoWhoseBundleIsGoneIsReplaced() {
    let unreadable = AxoInstance(pid: 9, bundlePath: nil, build: nil)
    XCTAssertEqual(
      LaunchHandover.decide(
        isAgentJob: false, replaceRequested: false, current: current, others: [unreadable]),
      .replace([unreadable], askFirst: true))
  }

  func testAReplacementTheRunningAxoAskedForDoesNotAskAgain() {
    let older = AxoInstance(pid: 9, bundlePath: "/dist/.Axo.app.previous", build: "259")
    XCTAssertEqual(
      LaunchHandover.decide(
        isAgentJob: false, replaceRequested: true, current: current, others: [older]),
      .replace([older], askFirst: false))
  }

  func testASignatureChangeChangesTheDefinition() {
    let signed = LaunchAgentDefinition(
      bundlePath: "/dist/Axo.app", plistSHA256: "abc", programSigningIdentity: "TEAM:axod")
    var renamed = signed
    renamed.programSigningIdentity = "TEAM:dev.leostera.axo.axod"
    XCTAssertEqual(RestartMethod.decide(registered: signed, current: renamed), .reregister)
  }

  func testADefinitionRecordedBeforeSignaturesDecodesAndReregisters() throws {
    let old = Data(#"{"bundlePath":"/dist/Axo.app","plistSHA256":"abc"}"#.utf8)
    let decoded = try JSONDecoder().decode(LaunchAgentDefinition.self, from: old)
    XCTAssertNil(decoded.programSigningIdentity)
    let current = LaunchAgentDefinition(
      bundlePath: "/dist/Axo.app", plistSHA256: "abc", programSigningIdentity: "TEAM:axod")
    XCTAssertEqual(RestartMethod.decide(registered: decoded, current: current), .reregister)
  }
}
