import AppKit
import AxoDaemonManager
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class AppSetupModel {
  static let shared = AppSetupModel(defaults: .standard, effects: AppSetupLive.effects, requiresStart: true)
  enum Step: Int, CaseIterable { case welcome, permissions, tryIt, ready }
  private(set) var step = Step.welcome
  private(set) var snapshot: SetupSnapshot?
  private(set) var isChecking = false
  private(set) var fixing: SetupItem?
  private(set) var isCheckingConnection = false
  private(set) var connection: SetupConnectionStatus?
  private(set) var connectionFailure: String?
  private(set) var failure: String?
  @ObservationIgnored private let logger = Logger(subsystem: "dev.leostera.axo", category: "setup")
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let effects: AppSetupEffects
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var connectionGeneration = 0
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private var window: AppSetupWindowController?
  @ObservationIgnored private var automaticConsidered = false
  @ObservationIgnored private let requiresStart: Bool
  @ObservationIgnored private let returningUser: Bool
  @ObservationIgnored private var started = false

  init(defaults: UserDefaults, effects: AppSetupEffects, requiresStart: Bool = false) {
    self.defaults = defaults; self.effects = effects; self.requiresStart = requiresStart
    returningUser = defaults.object(forKey: AxoPreferenceKey.selectedSession) != nil
      || defaults.object(forKey: AxoPreferenceKey.seenSessionsBaseline) != nil
  }
  func start(daemon: DaemonController, foregroundLaunch: Bool) {
    guard observer == nil else { return }
    started = true
    AppSetupLive.daemon = daemon
    observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          await self.refresh(force: true)
          self.considerAutomaticPresentation()
        }
      }
    Task {
      // Don't diagnose a normal restoring daemon as a broken installation.
      for _ in 0..<60 {
        guard daemon.status == .starting else { break }
        try? await Task.sleep(for: .milliseconds(500))
      }
      await refresh()
      considerAutomaticPresentation(foregroundLaunch: foregroundLaunch)
    }
  }

  func status(_ item: SetupItem) -> SetupStatus { snapshot?.status(item) ?? .checking }
  var readyCount: Int { SetupItem.allCases.filter { status($0).isReady }.count }
  var issueFingerprints: Set<String> {
    Set(SetupItem.allCases.compactMap { item in
      let state = status(item)
      guard state != .ready && state != .checking else { return nil }
      if item == .commandLine && defaults.bool(forKey: AxoPreferenceKey.cliCommandSetupOffered) { return nil }
      if item == .developerTools && defaults.bool(forKey: AxoPreferenceKey.developerToolsPromptDeclined) { return nil }
      return item.rawValue + ":" + state.rawValue
    })
  }
  var shouldPresentAutomatically: Bool {
    guard snapshot != nil else { return false }
    if !defaults.bool(forKey: AxoPreferenceKey.setupPresented) { return true }
    let acknowledged = Set(defaults.stringArray(forKey: AxoPreferenceKey.setupAcknowledgedIssues) ?? [])
    return !issueFingerprints.subtracting(acknowledged).isEmpty
  }
  /// Foreground handover can finish probing before the launchd app becomes active.
  /// Background/login launches remain quiet until the person activates Axo.
  func automaticPresentation(isActive: Bool, hasModal: Bool, foregroundLaunch: Bool) -> Step? {
    guard !automaticConsidered, snapshot != nil, !hasModal, isActive || foregroundLaunch else { return nil }
    automaticConsidered = true
    guard shouldPresentAutomatically else { return nil }
    return !defaults.bool(forKey: AxoPreferenceKey.setupPresented) && !returningUser ? .welcome : .permissions
  }
  private func considerAutomaticPresentation(foregroundLaunch: Bool = false) {
    guard let step = automaticPresentation(isActive: NSApp.isActive,
      hasModal: NSApp.modalWindow != nil, foregroundLaunch: foregroundLaunch) else { return }
    show(tour: step == .welcome)
  }

  func refresh(force: Bool = false) async {
    guard (!requiresStart || started), fixing == nil, (!isChecking || force) else { return }
    generation += 1
    let current = generation
    isChecking = true
    let value = await effects.check()
    guard current == generation else { return }
    let initial = snapshot == nil
    let previousCount = readyCount
    let previousProcess = snapshot?.permissions?.processId
    snapshot = value
    isChecking = false
    if initial || previousCount != readyCount || previousProcess != value.permissions?.processId {
      logger.info("event=setup.checked confirmed=\(self.readyCount) daemon_pid=\(value.permissions?.processId ?? 0)")
    }
    // A recovered grant leaves the acknowledgement set, so later revocation is a new issue.
    let old = Set(defaults.stringArray(forKey: AxoPreferenceKey.setupAcknowledgedIssues) ?? [])
    let recovered = SetupItem.allCases.filter { status($0).isReady }
    let remaining = old.filter { issue in
      !recovered.contains { issue.hasPrefix($0.rawValue + ":") }
    }
    if remaining != old {
      defaults.set(Array(remaining).sorted(), forKey: AxoPreferenceKey.setupAcknowledgedIssues)
    }
  }

  func fix(_ item: SetupItem) async {
    guard (!requiresStart || started), fixing == nil else { return }
    failure = nil
    logger.info("event=setup.repair_requested item=\(item.rawValue, privacy: .public)")
    if item.settingsURL != nil {
      do {
        try effects.guide(item, { [weak self] in Task { await self?.refresh() } },
          { [weak self] in self?.status(item).isReady == true })
      } catch { failure = error.localizedDescription }
      return
    }
    // Invalidate probes admitted before the prompt. Activation during an OS dialog must
    // not replace every row with a transient TCC failure. Recheck once the request finishes.
    generation += 1
    isChecking = false
    fixing = item
    // An admitted OS request stays owned if the view closes; no cancellation/retry on disappear.
    do { try await effects.fix(item) } catch { failure = error.localizedDescription }
    fixing = nil
    await refresh(force: true)
  }

  func next() {
    switch step {
    case .welcome: step = .permissions
    case .permissions: step = .tryIt
    case .tryIt: leaveConnectionStep(); step = .ready
    case .ready: finish()
    }
  }
  func back() {
    if step == .tryIt { leaveConnectionStep() }
    if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
  }
  func leaveConnectionStep() { connectionGeneration += 1; isCheckingConnection = false }
  func observeConnection() async {
    repeat {
      guard !Task.isCancelled, step == .tryIt else { return }
      await refreshConnection()
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
    } while !Task.isCancelled
  }
  func refreshConnection() async {
    guard (!requiresStart || started), !isCheckingConnection else { return }
    isCheckingConnection = true
    connectionGeneration += 1
    let current = connectionGeneration
    do {
      let result = try await effects.connectionStatus()
      guard current == connectionGeneration, step == .tryIt else { return }
      connection = result
      connectionFailure = nil
    } catch {
      guard current == connectionGeneration, step == .tryIt else { return }
      connection = nil
      connectionFailure = "Couldn’t reach the local Axo service. Check Login Items in Setup & Permissions."
    }
    if current == connectionGeneration { isCheckingConnection = false }
  }
  func openPairing() {
    guard !requiresStart || started else { return }
    effects.openPairing()
  }
  /// Invoked only after the view confirms terminal/process interruption.
  func restartDaemon() {
    generation += 1
    snapshot?.permissions = nil
    isChecking = false
    effects.restartDaemon()
    Task {
      for _ in 0..<60 {
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()
        if snapshot?.permissions != nil { break }
      }
    }
  }
  func finish() {
    defaults.set(true, forKey: AxoPreferenceKey.setupCompleted)
    acknowledge()
    window?.close()
    effects.openTerminal()
  }
  func acknowledge() {
    defaults.set(true, forKey: AxoPreferenceKey.setupPresented)
    defaults.set(Array(issueFingerprints).sorted(), forKey: AxoPreferenceKey.setupAcknowledgedIssues)
    // The unified tour replaces the separate CLI first-launch offer; opting out stays quiet.
    defaults.set(true, forKey: AxoPreferenceKey.cliCommandSetupOffered)
  }
  func show(tour: Bool = false) {
    guard !requiresStart || started else { return }
    automaticConsidered = true
    if tour { step = .welcome; leaveConnectionStep(); connection = nil }
    if window == nil {
      step = tour ? .welcome : .permissions
      connection = nil
      window = AppSetupWindowController(model: self) { [weak self] in
        self?.leaveConnectionStep()
        self?.acknowledge()
        self?.window = nil
      }
    }
    window?.present()
    Task { await refresh() }
  }
}
