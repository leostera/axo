import AppKit
import AxoDaemonManager
import SwiftUI
import XCTest
@testable import AxoMac

final class AppUpdatePresentationTests: XCTestCase {
  func testWindowIsExactlyCenteredInPrimaryUsableFrameIncludingNonzeroOrigins() {
    let primary = NSRect(x: 0, y: 48, width: 1512, height: 912)
    let frame = AppWindowPlacement.centered(size: NSSize(width: 620, height: 468), in: primary)
    XCTAssertEqual(frame.midX, primary.midX)
    XCTAssertEqual(frame.midY, primary.midY)
    XCTAssertTrue(primary.contains(frame))
    let unusual = NSRect(x: -1280, y: -720, width: 500, height: 350)
    let clamped = AppWindowPlacement.centered(size: NSSize(width: 620, height: 468), in: unusual)
    XCTAssertTrue(unusual.contains(clamped))
    XCTAssertEqual(clamped.midX, unusual.midX)
    XCTAssertEqual(clamped.midY, unusual.midY)
  }

  func testNotesSelectOnlyTheExactVersionAndEnforceBounds() {
    let changelog = "# Changelog\n\n## 0.71 (Mac app build 342, axod 83)\n\n### Added\n\n- Current release.\n\n## 0.7 (older release)\n\n- Older release."
    XCTAssertEqual(AppUpdateReleaseNotes.section(in: changelog, version: "0.71"), "### Added\n\n- Current release.")
    XCTAssertEqual(AppUpdateReleaseNotes.section(in: changelog, version: "0.7"), "- Older release.")
    XCTAssertNil(AppUpdateReleaseNotes.section(in: changelog, version: "0.6"))
    XCTAssertNil(AppUpdateReleaseNotes.section(in: String(repeating: "x", count: AppUpdateReleaseNotes.maximumBytes + 1), version: "0.71"))
    XCTAssertNil(AppUpdateReleaseNotes.section(in: "## 0.71\n" + String(repeating: "x", count: AppUpdateReleaseNotes.maximumSectionBytes + 1), version: "0.71"))
    XCTAssertNil(AppUpdateReleaseNotes.section(in: "## 0.71\n" + String(repeating: "x\n", count: 257), version: "0.71"))
  }

  @MainActor
  func testPresentationDistinguishesErrorsAndOnlyWarnsWhenAxodWillRestart() {
    let model = AppUpdatePresentation(runningVersion: "0.70", runningAxod: 82)
    XCTAssertEqual(model.state, .checking)
    model.state = .available(.installed(build: 342, axodBuild: 82, version: "0.71"))
    XCTAssertEqual(model.title, "Axo 0.71 is available")
    XCTAssertEqual(model.subtitle, "You have Axo 0.70.")
    XCTAssertNil(model.restartWarning)
    model.state = .available(.installed(build: 342, axodBuild: 83, version: "0.71"))
    XCTAssertNotNil(model.restartWarning)
    model.state = .failed("offline")
    XCTAssertEqual(model.title, "Couldn’t check for updates")
    XCTAssertNil(model.restartWarning)
    model.state = .current
    XCTAssertEqual(model.title, "Axo is up to date")
  }

  @MainActor
  func testRealUpdateWindowKeepsItsSizeAcrossEveryState() async throws {
    _ = NSApplication.shared
    let model = AppUpdatePresentation(runningVersion: "0.67", runningAxod: 83)
    let noAction = { XCTFail("Window layout must never install or invoke an action") }
    let controller = AppUpdateWindowController(content: AppUpdateOfferView(presentation: model,
      appIcon: try AppFixtureArtwork.icon(), install: noAction, skip: noAction, remind: noAction,
      checkAgain: noAction, close: noAction), onClose: {})
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }
    let content = try XCTUnwrap(window.contentViewController?.view)
    let release = try PublishedBuild(build: 339, axodBuild: 83, commit: String(repeating: "b", count: 40),
      version: "0.68", artifacts: ["aarch64-apple-darwin": "axo-0.68-bbbbbbbbbbbb-aarch64-apple-darwin.zip"])
    for state in [AppUpdatePresentation.State.checking, .current, .failed("Offline"), .unverifiable, .available(.published(release))] {
      model.state = state
      model.notes = .loaded("### Fixed\n\n" + String(repeating: "- Window content wraps within its width, never drives native window geometry.\n", count: 80))
      content.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
      content.layoutSubtreeIfNeeded()
      XCTAssertEqual(content.bounds.width, 620, accuracy: 1)
      XCTAssertEqual(content.bounds.height, 440, accuracy: 1)
      XCTAssertFalse(window.isVisible)
    }
    let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let directory = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] ?? FileManager.default.temporaryDirectory.path
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("axo-update-real-window.png"))
  }

  @MainActor
  func testUpdateWindowLightAndDarkFixturesNeverInstallOrOpenARealWindow() throws {
    _ = NSApplication.shared
    let release = try PublishedBuild(build: 342, axodBuild: 83, commit: String(repeating: "a", count: 40),
      version: "0.71", artifacts: ["aarch64-apple-darwin": "axo-0.71-aaaaaaaaaaaa-aarch64-apple-darwin.zip"])
    let model = AppUpdatePresentation(runningVersion: "0.70", runningAxod: 82)
    model.state = .available(.published(release))
    model.notes = .loaded("### Added\n\n- A startup checklist brings permission checks into one place.\n- See what each permission enables and recheck after changing Settings.\n\n### Improved\n\n- Update details appear before installation, with the current version and release notes.\n- Signed updates are verified before Axo restarts.")
    let noAction = { XCTFail("Rendering a fixture must never perform an updater action") }
    let view = AppUpdateOfferView(presentation: model, appIcon: try AppFixtureArtwork.icon(), install: noAction, skip: noAction,
      remind: noAction, checkAgain: noAction, close: noAction)
    for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
      let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
      hosting.appearance = NSAppearance(named: appearance)
      hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 440)
      hosting.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let directory = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] ?? FileManager.default.temporaryDirectory.path
      try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("axo-update-offer-\(name).png"))
    }
  }
}
