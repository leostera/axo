import AppKit
import AxoClient
import AxoDaemonManager
import Observation
import OSLog

/// The menu bar's "Check for Updates…", "Upgrade to Build N" once one is known: a newer build installed over this bundle (a `bazel build`
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
    case downloading(build: Int)
    case restarting(build: Int)
  }

  private(set) var available: AppUpgrade?
  private(set) var phase = Phase.idle

  @ObservationIgnored private let logger = Logger(subsystem: "dev.leostera.axo", category: "upgrade")
  @ObservationIgnored private let origin = RelayEndpoint.production.origin
  @ObservationIgnored private let team = AppUpgradeInstaller.runningTeam()
  @ObservationIgnored private var published: PublishedBuild?
  @ObservationIgnored private var publishedCheckedAt: Date?
  @ObservationIgnored private var timer: Timer?
  /// How stale the published build may be when the menu opens.
  private static let publishedFreshness: TimeInterval = 10 * 60
  private static let backgroundInterval: TimeInterval = 60 * 60

  private var bundle: URL { Bundle.main.bundleURL }
  private var running: Int? {
    (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
  }
  private var runningAxod: Int? {
    (Bundle.main.infoDictionary?["AXODBuildNumber"] as? String).flatMap(Int.init)
  }

  /// Checks now and then hourly; the menu also checks when it opens (`refresh`).
  func start() {
    guard timer == nil else { return }
    refresh(force: true)
    timer = Timer.scheduledTimer(withTimeInterval: Self.backgroundInterval, repeats: true) {
      _ in
      MainActor.assumeIsolated { AppUpgradeModel.shared.refresh(force: true) }
    }
  }

  /// Re-reads the bundle on disk at once, and the published build when it is stale.
  func refresh(force: Bool = false) {
    decide()
    let stale = publishedCheckedAt.map { Date().timeIntervalSince($0) > Self.publishedFreshness } ?? true
    guard team != nil, force || stale else { return }
    publishedCheckedAt = Date()
    Task {
      do {
        published = try await AppUpgradeInstaller.fetchPublished(origin: origin)
      } catch {
        logger.info(
          "event=upgrade.published_check_failed reason=\(error.localizedDescription, privacy: .public)")
      }
      decide()
    }
  }

  /// Checks the published build now; then upgrades, or says this is the newest.
  func checkForUpdates() {
    guard phase == .idle else { return }
    if available != nil { return upgrade() }
    guard let running else { return }
    phase = .checking
    publishedCheckedAt = Date()
    Task {
      var failure: String?
      if team != nil {
        do {
          published = try await AppUpgradeInstaller.fetchPublished(origin: origin)
        } catch {
          failure = error.localizedDescription
          logger.info(
            "event=upgrade.published_check_failed reason=\(error.localizedDescription, privacy: .public)")
        }
      }
      phase = .idle
      decide()
      if available != nil { return upgrade() }
      if let failure { return fail("Couldn’t check for updates", failure) }
      inform(
        team == nil ? "This Axo can’t update itself" : "Axo is up to date",
        team == nil
          ? "Build \(running) is not signed by a team, so it can’t check that a download is Axo’s. A newer build installed over it is still offered."
          : "Build \(running) is the newest.")
    }
  }

  func upgrade() {
    guard phase == .idle, let upgrade = available, let running else { return }
    guard confirm(upgrade, running: running) else { return }
    switch upgrade {
    case .installed(let build, _):
      restart(into: build)
    case .published(let published):
      guard let team, let bundleID = Bundle.main.bundleIdentifier else { return }
      phase = .downloading(build: published.build)
      logger.info("event=upgrade.download_started build=\(published.build, privacy: .public)")
      Task {
        do {
          let build = try await AppUpgradeInstaller.install(
            origin: origin, over: bundle, bundleIdentifier: bundleID, team: team, running: running)
          restart(into: build)
        } catch {
          logger.error(
            "event=upgrade.download_failed reason=\(error.localizedDescription, privacy: .public)")
          phase = .idle
          fail("Couldn’t upgrade to Axo build \(published.build)", error.localizedDescription)
        }
      }
    }
  }

  private func decide() {
    guard let running else { return }
    available = AppUpgrade.choose(
      running: running,
      installed: AppUpgradeInstaller.bundleBuild(of: bundle),
      installedAxod: AppUpgradeInstaller.bundleBuild(of: bundle, key: "AXODBuildNumber"),
      published: published,
      canVerifyDownloads: team != nil)
  }

  /// Asks only when the upgrade restarts axod, which restarts every terminal.
  private func confirm(_ upgrade: AppUpgrade, running: Int) -> Bool {
    guard let axod = upgrade.axodBuild, let runningAxod, axod != runningAxod else { return true }
    let alert = NSAlert()
    alert.messageText = "Upgrade to Axo build \(upgrade.build)?"
    alert.informativeText =
      "It comes with axod build \(axod) (this is \(runningAxod)), so axod restarts: terminals restart and Pi sessions resume."
    alert.addButton(withTitle: "Upgrade")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// The bundle on disk is `build` now: open a new instance of it, which replaces this one
  /// without asking (`--replace-running`) and hands over to launchd.
  func restart(into build: Int) {
    phase = .restarting(build: build)
    logger.info("event=upgrade.restart build=\(build, privacy: .public)")
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [AppAgentController.replaceRunningArgument]
    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
      guard let error else { return }
      Task { @MainActor in
        AppUpgradeModel.shared.phase = .idle
        AppUpgradeModel.shared.fail("Couldn’t start Axo build \(build)", error.localizedDescription)
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
