import AppKit
import AxoDaemonManager
import SwiftUI
import XCTest

@testable import AxoMac

@MainActor
final class AppAutomaticUpdatesTests: XCTestCase {
  private func defaults() -> UserDefaults {
    let name = "dev.leostera.axo.automatic-update-test.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }

  private func release(_ build: Int = 342) -> PublishedBuild {
    let commit = String(repeating: "a", count: 40)
    return try! PublishedBuild(build: build, axodBuild: 86, commit: commit, version: "0.71",
      artifacts: [PublishedBuild.targetTriplet: "axo-0.71-aaaaaaaaaaaa-\(PublishedBuild.targetTriplet).zip"])
  }

  private func until(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(condition(), "The owned operation did not settle")
  }

  func testDisabledByDefaultAndEnablingPersistsWithoutInstallingAnything() {
    let store = defaults()
    let updates = AppAutomaticUpdates(defaults: store)
    XCTAssertFalse(updates.isEnabled)
    XCTAssertFalse(updates.start(release(), install: { _, _ in XCTFail("No consent"); return 0 },
      didInstall: { _ in XCTFail("No restart") }, didFinish: {}))
    updates.setEnabled(true)
    XCTAssertTrue(AppAutomaticUpdates(defaults: store).isEnabled)
    XCTAssertFalse(updates.isInstalling)
    updates.setEnabled(false)
    XCTAssertFalse(AppAutomaticUpdates(defaults: store).isEnabled)
  }

  func testVerifiedInstallerResultCompletesHandoverOnce() async {
    let updates = AppAutomaticUpdates(defaults: defaults())
    updates.setEnabled(true)
    var installed: [Int] = []
    var finishes = 0
    XCTAssertTrue(updates.start(release(), install: { release, authorize in
      try authorize()
      return release.build
    }, didInstall: { installed.append($0) }, didFinish: { finishes += 1 }))
    await until { !updates.isInstalling }
    XCTAssertEqual(installed, [342])
    XCTAssertEqual(finishes, 1)
    XCTAssertNil(updates.failure)
  }

  func testDisableReenableRevokesOldAuthorityAndKeepsTheSlotUntilRetirement() async {
    let updates = AppAutomaticUpdates(defaults: defaults())
    updates.setEnabled(true)
    var pending: CheckedContinuation<Void, Never>?
    var writes = 0
    var restarts = 0
    updates.start(release(), install: { _, authorize in
      await withCheckedContinuation { pending = $0 }
      try authorize()
      writes += 1
      return 342
    }, didInstall: { _ in restarts += 1 }, didFinish: {})
    await until { pending != nil }
    updates.setEnabled(false)
    updates.setEnabled(true)
    XCTAssertTrue(updates.isInstalling)
    XCTAssertFalse(updates.start(release(), install: { _, _ in XCTFail("Still owned"); return 0 },
      didInstall: { _ in XCTFail("No restart") }, didFinish: {}))
    pending?.resume()
    await until { !updates.isInstalling }
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(restarts, 0)
    XCTAssertNil(updates.failure)
    XCTAssertTrue(updates.start(release(), install: { _, authorize in try authorize(); return 342 },
      didInstall: { _ in restarts += 1 }, didFinish: {}))
    await until { !updates.isInstalling }
    XCTAssertEqual(restarts, 1)
  }

  func testDisablingAfterCommitCannotStrandTheInstalledApp() async {
    let updates = AppAutomaticUpdates(defaults: defaults())
    updates.setEnabled(true)
    var committed: CheckedContinuation<Void, Never>?
    var restarts = 0
    updates.start(release(), install: { _, authorize in
      try authorize() // private fixture's replacement point
      await withCheckedContinuation { committed = $0 }
      return 342 // success means the already-authorized replacement committed
    }, didInstall: { _ in restarts += 1 }, didFinish: {})
    await until { committed != nil }
    updates.setEnabled(false)
    committed?.resume()
    await until { !updates.isInstalling }
    XCTAssertEqual(restarts, 1)
  }

  func testFailureIsVisibleAndRetriesAreBoundedAcrossReleases() async {
    let store = defaults()
    var now = Date(timeIntervalSince1970: 10_000)
    let updates = AppAutomaticUpdates(defaults: store, now: { now })
    updates.setEnabled(true)
    var attempts = 0
    let install: AppAutomaticUpdates.Install = { _, authorize in
      try authorize()
      attempts += 1
      now += 1_200 // even a long download backs off from failure, not its start
      throw AppUpgradeError.download("fixture failure")
    }
    updates.start(release(), install: install, didInstall: { _ in XCTFail("No restart") }, didFinish: {})
    await until { !updates.isInstalling }
    XCTAssertTrue(updates.failure?.contains("fixture failure") == true)
    now += AppAutomaticUpdates.retryInterval - 1
    XCTAssertFalse(updates.start(release(343), install: install, didInstall: { _ in }, didFinish: {}))
    now += 1
    XCTAssertTrue(updates.start(release(343), install: install, didInstall: { _ in }, didFinish: {}))
    await until { !updates.isInstalling }
    XCTAssertEqual(attempts, 2)
  }

  func testTransportCancellationIsQuietEvenIfTheInstallerWrapsIt() async {
    let updates = AppAutomaticUpdates(defaults: defaults())
    updates.setEnabled(true)
    var pending: CheckedContinuation<Void, Never>?
    updates.start(release(), install: { _, _ in
      await withCheckedContinuation { pending = $0 }
      throw AppUpgradeError.download("cancelled")
    }, didInstall: { _ in XCTFail("No restart") }, didFinish: {})
    await until { pending != nil }
    updates.setEnabled(false)
    pending?.resume()
    await until { !updates.isInstalling }
    XCTAssertNil(updates.failure)
  }

  func testSkipRemindAndNotificationDeduplicationHaveDistinctMeanings() async {
    let store = defaults()
    var now = Date(timeIntervalSince1970: 10_000)
    let updates = AppAutomaticUpdates(defaults: store, now: { now })
    updates.setEnabled(true)
    var installs = 0
    let install: AppAutomaticUpdates.Install = { release, authorize in
      try authorize(); installs += 1; return release.build
    }
    AppUpdateReminder.skip(build: 342, defaults: store)
    XCTAssertFalse(updates.start(release(), install: install, didInstall: { _ in }, didFinish: {}))
    AppUpdateReminder.remind(build: 342, defaults: store, now: now)
    XCTAssertFalse(updates.start(release(), install: install, didInstall: { _ in }, didFinish: {}))
    AppUpdateReminder.delivered(build: 342, defaults: store)
    // A delivered banner clears the reminder, but its deduplication key is NOT an install veto.
    XCTAssertTrue(updates.start(release(), install: install, didInstall: { _ in }, didFinish: {}))
    await until { !updates.isInstalling }
    XCTAssertEqual(installs, 1)
    now += AppAutomaticUpdates.retryInterval
    AppUpdateReminder.remind(build: 343, defaults: store, now: now)
    now += AppUpdateReminder.delay
    XCTAssertTrue(updates.start(release(343), install: install, didInstall: { _ in }, didFinish: {}))
    await until { !updates.isInstalling }
    XCTAssertEqual(installs, 2)
  }

  func testTheNativeSettingsControlRendersWithoutCheckingOrInstalling() async throws {
    let updates = AppAutomaticUpdates(defaults: defaults())
    let view = Form {
      AppUpdateSettingsSection(automatic: updates,
        setEnabled: { updates.setEnabled($0) }, check: { XCTFail("Rendering is not a check") })
    }.formStyle(.grouped)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 330),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
    window.contentView = hosting
    window.setContentSize(NSSize(width: 740, height: 330))
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    hosting.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let directory = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] ?? FileManager.default.temporaryDirectory.path
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("axo-automatic-updates.png"))
    XCTAssertFalse(updates.isEnabled)
    XCTAssertFalse(updates.isInstalling)
  }
}
