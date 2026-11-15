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
      connectionStatus: { SetupConnectionStatus(health: Self.snapshot().health!, account: .unlinked) },
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
    }, connectionStatus: { SetupConnectionStatus(health: Self.snapshot().health!, account: .unlinked) }, guide: { _, _, _ in XCTFail("Unexpected guide") },
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
  func testConnectionsAreReadOnlyAndPairingIsOptional() async {
    var checks = 0
    var pairingOpens = 0
    let e = AppSetupEffects(check: { Self.snapshot() }, fix: { _ in XCTFail("No repair") },
      connectionStatus: {
        checks += 1
        return SetupConnectionStatus(health: Self.snapshot().health!, account: .unlinked)
      }, guide: { _, _, _ in XCTFail("No guide") },
      openTerminal: {}, restartDaemon: {}, openPairing: { pairingOpens += 1 })
    let model = AppSetupModel(defaults: store(), effects: e)
    model.next(); model.next()
    XCTAssertEqual(model.step, .tryIt)
    await model.refreshConnection()
    XCTAssertEqual(checks, 1)
    XCTAssertEqual(model.connection?.account, .unlinked)
    XCTAssertTrue(model.connection?.health.ready == true)
    XCTAssertEqual(pairingOpens, 0, "Observing status never starts pairing")
    model.openPairing()
    XCTAssertEqual(pairingOpens, 1)
    model.next()
    XCTAssertEqual(model.step, .ready, "No account is required for local use")
    let inactive = AppSetupModel(defaults: store(), effects: e, requiresStart: true)
    inactive.next(); inactive.next()
    await inactive.refreshConnection()
    XCTAssertNil(inactive.connection, "Inactive fixtures cannot probe the person's Mac")
    XCTAssertEqual(checks, 1)
    let skipped = AppSetupModel(defaults: store(), effects: e)
    skipped.next(); skipped.next(); skipped.next()
    XCTAssertEqual(skipped.step, .ready)
    XCTAssertNil(skipped.connection, "Continuing without a result must not forge a connection")
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
  func testAutomationPromptKeepsOtherRowsStableAndDiscardsAnEarlierProbe() async throws {
    var checks = 0
    var oldReply: CheckedContinuation<SetupSnapshot, Never>?
    var prompt: CheckedContinuation<Void, Never>?
    var initial = Self.snapshot()
    initial.permissions = DaemonPermissions(processId: 42, accessibility: .granted, inputControl: .granted,
      screenRecording: .granted, developerTools: .granted, fullDiskAccess: .granted,
      automationFinder: .granted, automationSystemEvents: .notRunning)
    let e = AppSetupEffects(check: {
      checks += 1
      if checks == 2 { return await withCheckedContinuation { oldReply = $0 } }
      return checks == 1 ? initial : Self.snapshot(.notGranted)
    }, fix: { _ in await withCheckedContinuation { prompt = $0 } },
      connectionStatus: { SetupConnectionStatus(health: Self.snapshot().health!, account: .unlinked) }, guide: { _, _, _ in XCTFail("No guide") },
      openTerminal: {}, restartDaemon: {})
    let model = AppSetupModel(defaults: store(), effects: e)
    await model.refresh()
    let old = Task { await model.refresh(force: true) }
    for _ in 0..<100 { if oldReply != nil { break }; await Task.yield() }
    let stale = try XCTUnwrap(oldReply)
    let request = Task { await model.fix(.systemEvents) }
    for _ in 0..<100 { if prompt != nil { break }; await Task.yield() }
    let pending = try XCTUnwrap(prompt)
    stale.resume(returning: Self.snapshot(.notGranted))
    await old.value
    await model.refresh(force: true) // activation while the OS dialog is up
    XCTAssertEqual(checks, 2, "Do not probe TCC while an admitted prompt is pending")
    XCTAssertEqual(model.readyCount, 8, "Transient prompt-time replies must not revoke unrelated rows")
    XCTAssertEqual(model.fixing, .systemEvents)
    XCTAssertFalse(model.isChecking)
    pending.resume()
    await request.value
    XCTAssertEqual(checks, 3, "One fresh report after completion")
    XCTAssertNil(model.fixing)
    XCTAssertEqual(model.readyCount, 3, "A fresh post-prompt revocation must not be hidden by cached observations")
  }

  @MainActor
  func testForegroundUpgradePresentsEvenBeforeActivationButLoginStaysQuiet() async {
    let defaults = store()
    defaults.set("existing-session", forKey: AxoPreferenceKey.selectedSession)
    let model = AppSetupModel(defaults: defaults, effects: effects(check: { Self.snapshot() }))
    XCTAssertNil(model.automaticPresentation(isActive: false, hasModal: false, foregroundLaunch: true),
      "Wait for the first report without consuming the presentation")
    await model.refresh()
    XCTAssertNil(model.automaticPresentation(isActive: false, hasModal: false, foregroundLaunch: false))
    XCTAssertNil(model.automaticPresentation(isActive: false, hasModal: true, foregroundLaunch: true))
    XCTAssertEqual(model.automaticPresentation(isActive: false, hasModal: false, foregroundLaunch: true), .permissions)
    XCTAssertNil(model.automaticPresentation(isActive: true, hasModal: false, foregroundLaunch: true))
  }

  @MainActor
  func testRealSetupWindowStaysBoundedAcrossStepsWithoutShowingOrActivatingIt() async throws {
    _ = NSApplication.shared
    let model = AppSetupModel(defaults: store(), effects: effects(check: { Self.snapshot() }))
    await model.refresh()
    let controller = AppSetupWindowController(model: model, appIcon: try AppFixtureArtwork.icon(), onClose: {})
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }
    let content = try XCTUnwrap(window.contentViewController?.view)
    for step in 0..<4 {
      content.layoutSubtreeIfNeeded()
      // An offscreen NSHostingController only evaluates its changed graph when drawn.
      try renderWindowContent(content, name: "axo-setup-step-\(step)")
      try await Task.sleep(for: .milliseconds(30))
      content.layoutSubtreeIfNeeded()
      XCTAssertEqual(window.contentLayoutRect.width, 820, accuracy: 1)
      XCTAssertEqual(content.bounds.height, AppSetupWindowController.preferredSize(for: model.step).height,
        accuracy: 1, "Only the explicit step size may change the window")
      XCTAssertFalse(window.isVisible, "Fixture must never steal the person's focus")
      if step == 1 {
        try renderWindowContent(content, name: "axo-setup-real-window")
      }
      if step == 2 {
        try renderWindowContent(content, name: "axo-setup-connections")
        XCTAssertNotNil(model.connection, "Entering Connections must check automatically, without a button press")
      }
      if step < 3 { model.next() }
    }
  }

  @MainActor
  func testLateConnectionReplyCannotOverwriteAReenteredStep() async throws {
    var pending: CheckedContinuation<SetupConnectionStatus, Never>?
    var reads = 0
    let e = AppSetupEffects(check: { Self.snapshot() }, fix: { _ in XCTFail("No repair") },
      connectionStatus: {
        reads += 1
        if reads == 1 { return await withCheckedContinuation { pending = $0 } }
        return SetupConnectionStatus(health: Self.snapshot().health!, account: .unlinked)
      }, guide: { _, _, _ in XCTFail("No guide") }, openTerminal: {}, restartDaemon: {})
    let model = AppSetupModel(defaults: store(), effects: e)
    model.next(); model.next()
    let stale = Task { await model.refreshConnection() }
    for _ in 0..<100 { if pending != nil { break }; await Task.yield() }
    let reply = try XCTUnwrap(pending)
    model.back(); model.next()
    await model.refreshConnection()
    reply.resume(returning: SetupConnectionStatus(health: Self.snapshot().health!, account: .connected))
    await stale.value
    XCTAssertEqual(model.connection?.account, .unlinked)
    XCTAssertFalse(model.isCheckingConnection)
  }

  @MainActor
  func testOneUnverifiedCheckIsNamedAboveTheFullHeightList() async throws {
    var source = Self.snapshot()
    source.permissions = DaemonPermissions(processId: 42, accessibility: .granted, inputControl: .granted,
      screenRecording: .granted, developerTools: .granted, fullDiskAccess: .granted,
      automationFinder: .granted, automationSystemEvents: .notRunning)
    let model = AppSetupModel(defaults: store(), effects: effects(check: { source }))
    await model.refresh()
    model.next()
    XCTAssertEqual(model.readyCount, 8)
    XCTAssertEqual(model.status(.systemEvents), .notRunning, "Unverified must never be described as a denied grant")
    let controller = AppSetupWindowController(model: model, appIcon: try AppFixtureArtwork.icon(), onClose: {})
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }
    let content = try XCTUnwrap(window.contentViewController?.view)
    content.layoutSubtreeIfNeeded()
    try renderWindowContent(content, name: "axo-setup-one-unverified")
    XCTAssertEqual(content.bounds.height, 1000, accuracy: 1)
    XCTAssertFalse(window.isVisible)
  }

  func testAccountStatusNeverConfusesOfflineOrUnknownWithUnlinked() {
    func remote(_ state: RemoteAccessConnectionState, linked: Bool?) -> RemoteAccessStatus {
      RemoteAccessStatus(state: state, connectedSinceUnixMillis: nil, hostName: "fixture",
        hostKind: "macos", lastError: nil, linked: linked)
    }
    XCTAssertEqual(SetupAccountStatus(remote(.disconnected, linked: false)), .unlinked)
    XCTAssertEqual(SetupAccountStatus(remote(.disconnected, linked: true)), .offline)
    XCTAssertEqual(SetupAccountStatus(remote(.disconnected, linked: nil)), .unknown)
    XCTAssertEqual(SetupAccountStatus(remote(.connecting, linked: true)), .connecting)
    XCTAssertEqual(SetupAccountStatus(remote(.connected, linked: true)), .connected)
    XCTAssertEqual(SetupAccountStatus(nil), .unknown)
  }

  @MainActor
  private func renderWindowContent(_ content: NSView, name: String) throws {
    let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let folder = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] ?? FileManager.default.temporaryDirectory.path
    try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
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
