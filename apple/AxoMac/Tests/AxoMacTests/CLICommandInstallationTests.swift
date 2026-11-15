import AppKit
import SwiftUI
import XCTest

@testable import AxoMac

final class CLICommandInstallationTests: XCTestCase {
  struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-cli-setting-\(UUID())")
    var bundle: URL { root.appendingPathComponent("Axo.app") }
    var source: URL { bundle.appendingPathComponent("Contents/Helpers/axo") }
    var destination: URL { root.appendingPathComponent("bin/axo") }

    init() throws {
      try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("fixture, never executed".utf8).write(to: source)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
    }
    func link(to target: URL) throws {
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
  }

  @MainActor
  func testInspectionNeverInstallsAndExplicitInstallIsIdempotent() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var calls = 0
    let model = CLICommandInstallation(bundle: fixture.bundle, destination: fixture.destination) { source in
      calls += 1
      try fixture.link(to: source)
    }
    XCTAssertEqual(model.status, .missing)
    model.refresh()
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    await model.install()
    XCTAssertEqual(model.status, .installed)
    XCTAssertNil(model.failure)
    await model.install()
    XCTAssertEqual(calls, 1)
  }

  @MainActor
  func testForeignRegularAndDanglingLinksAndDirectoriesArePreserved() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var calls = 0
    let model = CLICommandInstallation(bundle: fixture.bundle, destination: fixture.destination) { _ in calls += 1 }
    try fixture.link(to: fixture.root.appendingPathComponent("missing-foreign"))
    model.refresh()
    XCTAssertEqual(model.status, .conflict)
    await model.install()
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path), fixture.root.appendingPathComponent("missing-foreign").path)
    try FileManager.default.removeItem(at: fixture.destination)
    try Data("foreign command".utf8).write(to: fixture.destination)
    model.refresh()
    XCTAssertEqual(model.status, .conflict)
    await model.install()
    XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "foreign command")
    try FileManager.default.removeItem(at: fixture.destination)
    try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
    model.refresh()
    XCTAssertEqual(model.status, .conflict)
    await model.install()
    XCTAssertEqual(calls, 0)
  }

  @MainActor
  func testCancelledAuthorizationCanRetryAndLostReceiptReconcilesActualLink() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var calls = 0
    let model = CLICommandInstallation(bundle: fixture.bundle, destination: fixture.destination) { source in
      calls += 1
      if calls == 2 { try fixture.link(to: source) }
      throw NSError(domain: "fixture", code: -128, userInfo: [NSLocalizedDescriptionKey: "Installation cancelled"])
    }
    await model.install()
    XCTAssertEqual(model.status, .missing)
    XCTAssertEqual(model.failure, "Installation cancelled")
    XCTAssertFalse(model.isInstalling)
    await model.install()
    XCTAssertEqual(model.status, .installed)
    XCTAssertNil(model.failure, "A lost receipt must not claim the installed link is absent")
  }

  @MainActor
  func testOnlyOneInstallationCanWaitForAuthorization() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var calls = 0
    var pending: CheckedContinuation<Void, Never>?
    let model = CLICommandInstallation(bundle: fixture.bundle, destination: fixture.destination) { source in
      calls += 1
      await withCheckedContinuation { pending = $0 }
      try fixture.link(to: source)
    }
    let first = Task { await model.install() }
    let deadline = Date().addingTimeInterval(2)
    while pending == nil && Date() < deadline { await Task.yield() }
    let continuation = try XCTUnwrap(pending)
    await model.install()
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(model.isInstalling)
    continuation.resume()
    await first.value
    XCTAssertEqual(model.status, .installed)
  }

  @MainActor
  func testMissingHelperAndTranslocatedCopyNeverRunInstaller() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var calls = 0
    let missing = CLICommandInstallation(bundle: fixture.root.appendingPathComponent("absent.app"), destination: fixture.destination) { _ in calls += 1 }
    await missing.install()
    guard case .unavailable = missing.status else { return XCTFail("Missing tool must be unavailable") }
    let translocated = CLICommandInstallation(bundle: fixture.root.appendingPathComponent("AppTranslocation/Axo.app"), destination: fixture.destination) { _ in calls += 1 }
    await translocated.install()
    guard case .unavailable(let reason) = translocated.status else { return XCTFail("Move the app before installing") }
    XCTAssertTrue(reason.contains("Move Axo"))
    XCTAssertEqual(calls, 0)
  }

  @MainActor
  func testCommandSettingsRendersWithoutLaunchingAnAppOrInstallingACommand() throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let model = CLICommandInstallation(bundle: fixture.bundle, destination: fixture.destination) { _ in XCTFail("Rendering must never install") }
    let view = Form { CLICommandSettingsSection(installation: model) }.formStyle(.grouped)
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
    hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 230)
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let directory = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] ?? FileManager.default.temporaryDirectory.path
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("axo-cli-settings.png"))
    XCTAssertEqual(model.status, .missing)
  }
}
