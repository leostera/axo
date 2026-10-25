import AxoProtocol
import XCTest

@testable import AxoMac

@MainActor
final class ViewportReporterTests: XCTestCase {
  private func viewport(width: Double) -> ClientViewport {
    ClientViewport(
      terminalArea: .init(width: width, height: 600), backingScale: 2,
      cell: .init(width: 16, height: 34),
      padding: .init(top: 10, bottom: 10, left: 2, right: 2), dividerThickness: 1)!
  }

  private func settle() async throws {
    try await Task.sleep(for: .milliseconds(80))
  }

  func testSendsOnlyTheLatestViewportOncePerChangeAndAgainAfterReconnecting() async throws {
    let client = FakeAxodClient()
    let reporter = ViewportReporter(client: client, debounce: .milliseconds(10))
    reporter.isSupported = { true }

    reporter.report(viewport(width: 800))
    reporter.report(viewport(width: 1000))
    try await settle()
    XCTAssertEqual(client.viewports, [viewport(width: 1000)])

    reporter.report(viewport(width: 1000))
    try await settle()
    XCTAssertEqual(client.viewports.count, 1, "an unchanged viewport is not resent")

    reporter.reconnected()
    try await settle()
    XCTAssertEqual(client.viewports, [viewport(width: 1000), viewport(width: 1000)])
  }

  func testOlderDaemonsAreNotAsked() async throws {
    let client = FakeAxodClient()
    let reporter = ViewportReporter(client: client, debounce: .milliseconds(10))
    reporter.isSupported = { false }
    reporter.report(viewport(width: 1000))
    try await settle()
    XCTAssertEqual(client.viewports, [])
  }

  func testEmptyAreasAreNotViewports() {
    XCTAssertNil(
      ClientViewport(
        terminalArea: .init(width: 0, height: 600), backingScale: 2,
        cell: .init(width: 16, height: 34),
        padding: .init(top: 0, bottom: 0, left: 0, right: 0), dividerThickness: 1))
  }

  func testTheReportedPaddingIsTheConfiguredPadding() {
    XCTAssertTrue(GhosttyRuntime.axoConfigDefaults.contains("window-padding-x = 2,2"))
    XCTAssertTrue(GhosttyRuntime.axoConfigDefaults.contains("window-padding-y = 10,10"))
  }
}
