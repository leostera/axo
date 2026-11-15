import AppKit
import AxoProtocol
import SwiftUI
import XCTest
@testable import AxoMac

final class AppSetupTests: XCTestCase {
  @MainActor
  private func store() -> UserDefaults {
    let name = "axo-setup-test-\(UUID())"
    let result = UserDefaults(suiteName: name)!
    addTeardownBlock { result.removePersistentDomain(forName: name) }
    return result
  }
  static func snapshot(_ access: PermissionAccess = .granted, locked: Bool = false) -> SetupSnapshot {
    SetupSnapshot(health: DaemonHealth(version: "fixture", buildNumber: 83, status: "running"),
      permissions: DaemonPermissions(processId: 42, accessibility: access, inputControl: access,
        screenRecording: access, developerTools: access, fullDiskAccess: access,
        automationFinder: access, automationSystemEvents: access, locked: locked),
      loginItemsEnabled: true, notifications: .ready, commandLine: .ready)
  }
  @MainActor
  private func effects(check: @escaping () async -> SetupSnapshot) -> AppSetupEffects {
    AppSetupEffects(check: check, fix: { _ in XCTFail("No repair expected") },
      testConnection: { "Connection verified; no commands ran." },
      guide: { _, _, _ in XCTFail("No settings window expected") },
      openTerminal: { XCTFail("No terminal open expected") }, restartDaemon: { XCTFail("No restart expected") })
  }

  @MainActor
  func testNotificationTimeoutAndLateCallbackResumeOnlyOnce() async {
    let status: SetupStatus = await withCheckedContinuation { continuation in
      let pending = AppSetupLive.NotificationReply(continuation)
      pending.finish(.unknown) // timeout wins
      pending.finish(.ready) // a late OS callback cannot forge a second result
    }
    XCTAssertEqual(status, .unknown)
  }

  @MainActor
  func testCheckHasNoEffectsAndUnknownNeverBecomesGranted() async {
    var source = Self.snapshot(.unknown)
    let model = AppSetupModel(defaults: store(), effects: effects(check: { source }))
    XCTAssertEqual(model.status(.accessibility), .checking)
    await model.refresh()
    XCTAssertEqual(model.readyCount, 3)
    XCTAssertEqual(model.status(.accessibility), .unknown)
    XCTAssertFalse(model.snapshot!.computerUseReady)
    source = Self.snapshot()
    await model.refresh()
    XCTAssertEqual(model.readyCount, 9)
    XCTAssertTrue(model.snapshot!.computerUseReady)
    source = Self.snapshot(locked: true)
    await model.refresh()
    XCTAssertFalse(model.snapshot!.computerUseReady, "Permission is not permission to operate the lock screen")
    source.permissions = nil
    await model.refresh()
    XCTAssertEqual(model.status(.screenRecording), .unknown)
  }

  @MainActor
  func testAcknowledgedIssuesStayQuietUntilRecoveryThenRevocation() async {
    let defaults = store()
    var source = Self.snapshot(.notGranted)
    let model = AppSetupModel(defaults: defaults, effects: effects(check: { source }))
    await model.refresh()
    XCTAssertTrue(model.shouldPresentAutomatically)
    model.acknowledge()
    XCTAssertFalse(model.shouldPresentAutomatically)
    await model.refresh()
    XCTAssertFalse(model.shouldPresentAutomatically)
    source = Self.snapshot()
    await model.refresh()
    source = Self.snapshot(.notGranted)
    await model.refresh()
    XCTAssertTrue(model.shouldPresentAutomatically)
    XCTAssertFalse(defaults.bool(forKey: AxoPreferenceKey.setupCompleted))
    // Preferences contain acknowledgements only, never a cached OS grant.
    XCTAssertTrue(defaults.stringArray(forKey: AxoPreferenceKey.setupAcknowledgedIssues)?.isEmpty == true)
  }

  @MainActor
  func testLateProbeCannotOverwriteNewerObservation() async throws {
    var first: CheckedContinuation<SetupSnapshot, Never>?
    var calls = 0
    let model = AppSetupModel(defaults: store(), effects: effects(check: {
      calls += 1
      if calls == 1 { return await withCheckedContinuation { first = $0 } }
      return Self.snapshot(.notGranted)
    }))
    let old = Task { await model.refresh() }
    let deadline = Date().addingTimeInterval(2)
    while first == nil && Date() < deadline { await Task.yield() }
    let continuation = try XCTUnwrap(first)
    await model.refresh(force: true)
    continuation.resume(returning: Self.snapshot())
    await old.value
    XCTAssertEqual(model.status(.accessibility), .needsSetup)
    XCTAssertFalse(model.isChecking)
  }

  @MainActor
  func testPermissionRepairsAreSerializedAndClosingTheViewDoesNotCancelAnAdmittedRequest() async throws {
    var pending: CheckedContinuation<Void, Never>?
    var calls = 0
    let e = AppSetupEffects(check: { Self.snapshot() }, fix: { _ in
      calls += 1
      await withCheckedContinuation { pending = $0 }
    }, testConnection: { "ok" }, guide: { _, _, _ in XCTFail("Unexpected guide") },
      openTerminal: {}, restartDaemon: { XCTFail("Unexpected restart") })
    let model = AppSetupModel(defaults: store(), effects: e)
    let first = Task { await model.fix(.finder) }
    let deadline = Date().addingTimeInterval(2)
    while pending == nil && Date() < deadline { await Task.yield() }
    let continuation = try XCTUnwrap(pending)
    model.acknowledge() // equivalent to closing the window; no task cancellation or retry
    await model.fix(.systemEvents)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(model.fixing, .finder)
    continuation.resume()
    await first.value
    XCTAssertNil(model.fixing)
  }

  @MainActor
  func testTryStepRequiresActualResultOrExplicitSkipAndFixtureStartupCannotRunLiveChecks() async {
    var testCalls = 0
    let defaults = store()
    let e = AppSetupEffects(check: { Self.snapshot(.unknown) }, fix: { _ in XCTFail("No repair") },
      testConnection: { testCalls += 1; return "Axo → axod verified" }, guide: { _, _, _ in XCTFail("No guide") },
      openTerminal: {}, restartDaemon: {})
    let model = AppSetupModel(defaults: defaults, effects: e)
    model.next(); model.next()
    XCTAssertEqual(model.step, .tryIt)
    model.next()
    XCTAssertEqual(model.step, .tryIt, "Opening the test screen is not a passing test")
    await model.testConnection()
    XCTAssertEqual(testCalls, 1)
    model.next()
    XCTAssertEqual(model.step, .ready)
    let inactive = AppSetupModel(defaults: defaults, effects: e, requiresStart: true)
    await inactive.refresh()
    await inactive.fix(.finder)
    XCTAssertNil(inactive.snapshot, "A fixture without normal startup never probes the person's Mac")
    let skipped = AppSetupModel(defaults: store(), effects: e)
    skipped.next(); skipped.next(); skipped.skipTest()
    XCTAssertEqual(skipped.step, .ready)
    XCTAssertNil(skipped.testResult, "Skipping never forges a successful test")
  }

  @MainActor
  func testWelcomePermissionAndGuideFixturesRenderWithoutShowingWindowsOrRequestingPermissions() async throws {
    _ = NSApplication.shared
    var source = Self.snapshot()
    source.permissions = DaemonPermissions(processId: 42, accessibility: .notGranted, inputControl: .notGranted,
      screenRecording: .notGranted, developerTools: .granted, fullDiskAccess: .unknown,
      automationFinder: .granted, automationSystemEvents: .notRunning)
    source.notifications = .needsSetup
    let model = AppSetupModel(defaults: store(), effects: effects(check: { source }))
    await model.refresh()
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      try render(AppSetupView(model: model, appIcon: try AppFixtureArtwork.icon()).environment(\.colorScheme, scheme),
        name: "axo-setup-welcome-\(name)", width: 900, height: 720)
    }
    model.next()
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      try render(AppSetupView(model: model, appIcon: try AppFixtureArtwork.icon()).environment(\.colorScheme, scheme),
        name: "axo-setup-permissions-\(name)", width: 900, height: 720)
    }
    try render(PermissionGuideView(item: .accessibility, executable: URL(fileURLWithPath: "/fixture/Axo.app/Contents/Helpers/axod"),
      close: { XCTFail("Rendering cannot close real windows") }), name: "axo-permission-guide", width: 392, height: 165)
  }

  @MainActor
  private func render(_ view: some View, name: String, width: CGFloat, height: CGFloat) throws {
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = NSAppearance(named: name.hasSuffix("dark") ? .darkAqua : .aqua)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let folder = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] ?? FileManager.default.temporaryDirectory.path
    try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
  }
}
