import AppKit
import AxoClient
import AxoDaemonManager
import Observation
import OSLog
import SwiftUI

/// The menu bar's "Check for Updates…", "Upgrade Axo" once one is known: a newer build installed over this bundle (a `bazel build`
/// at dist/Axo.app) is a restart; otherwise a newer build published at axo.leostera.dev is
/// downloaded, checked against this app's signature and swapped in first. Either way the new
/// Axo replaces this one through launchd (`AppLaunchHandover`), so it stays kept alive.
@MainActor
@Observable
final class AppUpgradeModel {
  static let shared = AppUpgradeModel()

  enum Phase: Equatable {
    case idle
    case checking
    case downloading(PublishedBuild)
    case restarting(build: Int)
  }

  private(set) var available: AppUpgrade?
  private(set) var phase = Phase.idle
  let automatic = AppAutomaticUpdates()

  @ObservationIgnored private let logger = Logger(subsystem: "dev.leostera.axo", category: "upgrade")
  @ObservationIgnored private let origin = RelayEndpoint.production.origin
  @ObservationIgnored private let team = AppUpgradeInstaller.runningTeam()
  @ObservationIgnored private var published: PublishedBuild?
  @ObservationIgnored private var publishedCheckedAt: Date?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var backgroundCheckedAt: Date?
  @ObservationIgnored private var downloadPanel: NSPanel?
  @ObservationIgnored private var updateWindow: AppUpdateWindowController?
  @ObservationIgnored private var notesTask: Task<Void, Never>?
  @ObservationIgnored private var publishedGeneration = 0
  private let updatePresentation = AppUpdatePresentation(
    runningVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
    runningAxod: (Bundle.main.infoDictionary?["AXODBuildNumber"] as? String).flatMap(Int.init))
  /// How stale the published build may be when the menu opens.
  private static let publishedFreshness: TimeInterval = 10 * 60
  private static let backgroundInterval: TimeInterval = 60
  private static let manualBackgroundInterval: TimeInterval = 60 * 60

  private var bundle: URL { Bundle.main.bundleURL }

  /// This Axo as the About pane shows it: "Axo 0.2 (abc1234, build 269)".
  static var runningTitle: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let commit = (info?["AXOGitCommit"] as? String).map { String($0.prefix(7)) } ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "Axo \(version) (\(commit), build \(build))"
  }
  private var running: Int? {
    (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
  }
  private var runningAxod: Int? {
    (Bundle.main.infoDictionary?["AXODBuildNumber"] as? String).flatMap(Int.init)
  }

  /// Poll once a minute when opted in; otherwise keep hourly background checks.
  func start() {
    guard timer == nil else { return }
    backgroundCheckedAt = Date()
    refresh(force: true)
    timer = Timer.scheduledTimer(withTimeInterval: Self.backgroundInterval, repeats: true) {
      _ in
      MainActor.assumeIsolated { AppUpgradeModel.shared.backgroundTick() }
    }
  }

  private func backgroundTick() {
    let interval = automatic.isEnabled ? Self.backgroundInterval : Self.manualBackgroundInterval
    guard backgroundCheckedAt.map({ Date().timeIntervalSince($0) >= interval }) ?? true else { return }
    backgroundCheckedAt = Date()
    refresh(force: true)
  }

  func setAutomaticUpdates(_ enabled: Bool) {
    automatic.setEnabled(enabled)
    if enabled { refresh(force: true) }
  }

  /// Re-reads the bundle on disk at once, and the published build when it is stale.
  func refresh(force: Bool = false) {
    decide()
    let stale = publishedCheckedAt.map { Date().timeIntervalSince($0) > Self.publishedFreshness } ?? true
    guard phase == .idle, team != nil, force || stale else { return }
    publishedCheckedAt = Date()
    publishedGeneration += 1
    let generation = publishedGeneration
    Task {
      do {
        let release = try await AppUpgradeInstaller.fetchPublished(origin: origin)
        guard generation == publishedGeneration else { return }
        published = release
        decide()
        automaticallyInstall(release)
      } catch {
        guard generation == publishedGeneration else { return }
        logger.info("event=upgrade.published_check_failed reason=\(error.localizedDescription, privacy: .public)")
      }
      decide()
    }
  }

  /// A manual check always presents the update window, never implicitly installs. Only the
  /// notification's explicitly named Upgrade action opts into askFirst: false.
  func checkForUpdates(askFirst: Bool = true) {
    guard phase == .idle else {
      if askFirst && phase == .checking { showUpdateWindow() }
      return
    }
    guard let running else {
      updatePresentation.state = .failed("This copy has no valid build number. Install a signed Axo release.")
      if askFirst { showUpdateWindow() }
      return
    }
    phase = .checking
    if askFirst {
      updatePresentation.state = .checking
      showUpdateWindow()
    }
    publishedCheckedAt = Date()
    publishedGeneration += 1
    let generation = publishedGeneration
    Task {
      var failure: String?
      if team != nil {
        do {
          let release = try await AppUpgradeInstaller.fetchPublished(origin: origin)
          guard generation == publishedGeneration else { return }
          published = release
        } catch {
          guard generation == publishedGeneration else { return }
          failure = error.localizedDescription
        }
      }
      phase = .idle
      decide()
      // A network failure must not turn a stale cached publication into a fresh-check result.
      let installed: Bool = if case .installed = available { true } else { false }
      if let failure, !installed {
        if askFirst { updatePresentation.state = .failed(failure) }
        else { fail("Couldn’t check for updates", failure) }
        return
      }
      if let available {
        if askFirst { showOffer(available) } else { upgrade() }
      } else if askFirst {
        updatePresentation.state = team == nil ? .unverifiable : .current
      } else {
        inform(team == nil ? "This Axo can’t update itself" : "Axo is up to date",
          "\(Self.runningTitle) has no newer verified update available (build \(running)).")
      }
    }
  }

  private func showOffer(_ update: AppUpgrade) {
    notesTask?.cancel()
    updatePresentation.state = .available(update)
    updatePresentation.notes = .loading
    guard updateWindow != nil, case .published(let release) = update else { return }
    notesTask = Task {
      let notes = try? await AppUpdateReleaseNotes.fetch(release)
      guard !Task.isCancelled, updatePresentation.state == .available(update) else { return }
      updatePresentation.notes = notes.map(AppUpdatePresentation.Notes.loaded) ?? .unavailable
    }
  }

  private func showUpdateWindow() {
    if updateWindow == nil {
      let view = AppUpdateOfferView(presentation: updatePresentation,
        install: { [weak self] in self?.installPresentedUpdate() },
        skip: { [weak self] in self?.skipPresentedUpdate() },
        remind: { [weak self] in self?.remindPresentedUpdate() },
        checkAgain: { [weak self] in self?.checkForUpdates() },
        close: { [weak self] in self?.closeUpdateWindow() })
      updateWindow = AppUpdateWindowController(content: view) { [weak self] in
        self?.notesTask?.cancel()
        self?.updateWindow = nil
      }
    }
    updateWindow?.present()
  }

  private func installPresentedUpdate() {
    guard case .available(let shown) = updatePresentation.state else { return }
    // Background refreshes may discover a different candidate. Re-present it for review,
    // rather than install anything other than the version the person was looking at.
    guard available == shown else { checkForUpdates(); return }
    upgrade()
  }
  private func skipPresentedUpdate() {
    guard case .available(let shown) = updatePresentation.state else { return }
    AppUpdateReminder.skip(build: shown.build, defaults: .standard)
    closeUpdateWindow()
  }
  private func remindPresentedUpdate() {
    guard case .available(let shown) = updatePresentation.state else { return }
    AppUpdateReminder.remind(build: shown.build, defaults: .standard, now: Date())
    closeUpdateWindow()
  }
  private func closeUpdateWindow() {
    notesTask?.cancel()
    updateWindow?.close()
    updateWindow = nil
  }

  func upgrade() {
    guard phase == .idle, let upgrade = available, let running else { return }
    guard confirm(upgrade, running: running) else { return }
    closeUpdateWindow()
    publishedGeneration += 1
    switch upgrade {
    case .installed(let build, _, _):
      restart(into: build)
    case .published(let published):
      guard let team, let bundleID = Bundle.main.bundleIdentifier else { return }
      phase = .downloading(published)
      showDownloadProgress(published)
      logger.info("event=upgrade.download_started build=\(published.build, privacy: .public)")
      Task {
        do {
          let build = try await AppUpgradeInstaller.install(
            origin: origin, published: published, over: bundle, bundleIdentifier: bundleID, team: team, running: running)
          closeDownloadProgress()
          restart(into: build)
        } catch {
          logger.error(
            "event=upgrade.download_failed reason=\(error.localizedDescription, privacy: .public)")
          closeDownloadProgress()
          phase = .idle
          fail("Couldn’t upgrade to Axo \(published.version)", error.localizedDescription)
        }
      }
    }
  }

  private func automaticallyInstall(_ release: PublishedBuild) {
    guard phase == .idle, updateWindow == nil, available == .published(release),
      let running, let team, let bundleID = Bundle.main.bundleIdentifier else { return }
    let accepted = automatic.start(release,
      install: { [self] release, authorize in
        try await AppUpgradeInstaller.install(
          origin: origin, published: release, over: bundle, bundleIdentifier: bundleID,
          team: team, running: running, authorizeInstallation: authorize)
      },
      didInstall: { [weak self] build in self?.restart(into: build, automatically: true) },
      didFinish: { [weak self] in
        if self?.phase == .downloading(release) { self?.phase = .idle }
      })
    if accepted { phase = .downloading(release) }
  }

  private func showDownloadProgress(_ release: PublishedBuild) {
    closeDownloadProgress()
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.title = "Upgrading Axo"
    panel.isReleasedWhenClosed = false
    let content = NSHostingController(rootView: AppUpgradeDownloadProgress(release: release))
    panel.contentViewController = content
    panel.setContentSize(content.view.fittingSize)
    AppWindowPlacement.centerOnPrimaryScreen(panel)
    downloadPanel = panel
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  private func closeDownloadProgress() {
    downloadPanel?.close()
    downloadPanel = nil
  }

  private func decide() {
    guard let running else { return }
    available = AppUpgrade.choose(
      running: running,
      installed: AppUpgradeInstaller.bundleBuild(of: bundle),
      installedAxod: AppUpgradeInstaller.bundleBuild(of: bundle, key: "AXODBuildNumber"),
      installedVersion: AppUpgradeInstaller.bundleVersion(of: bundle),
      published: published,
      canVerifyDownloads: team != nil)
    if !automatic.isEnabled, phase == .idle, updateWindow == nil, let available {
      Task { await AppUpgradeNotifications.shared.notify(available, running: running) }
    }
  }

  /// Asks only when the upgrade restarts axod, which restarts every terminal.
  private func confirm(_ upgrade: AppUpgrade, running: Int) -> Bool {
    guard let axod = upgrade.axodBuild, let runningAxod, axod != runningAxod else { return true }
    let alert = NSAlert()
    alert.messageText = "Upgrade to \(upgrade.title)?"
    alert.informativeText =
      "It comes with axod build \(axod) (this is \(runningAxod)), so axod, terminals and Pi processes restart. Conversation histories are kept; automatic continuation requires a compatible Pi SDK."
    alert.addButton(withTitle: "Upgrade")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// The bundle on disk is `build` now: open a new instance of it, which replaces this one
  /// without asking (`--replace-running`) and hands over to launchd.
  func restart(into build: Int, automatically: Bool = false) {
    phase = .restarting(build: build)
    logger.info("event=upgrade.restart build=\(build, privacy: .public)")
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = !automatically
    configuration.arguments = [AppAgentController.replaceRunningArgument]
    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { [weak self] _, error in
      guard let error else { return }
      Task { @MainActor in
        guard let self else { return }
        self.phase = .idle
        if automatically {
          self.logger.error("event=upgrade.automatic_restart_failed build=\(build, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
          self.automatic.reportRestartFailure(error.localizedDescription)
        } else {
          self.fail("Couldn’t start Axo build \(build)", error.localizedDescription)
        }
      }
    }
  }

  private func inform(_ message: String, _ detail: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  private func fail(_ message: String, _ detail: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = detail
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
