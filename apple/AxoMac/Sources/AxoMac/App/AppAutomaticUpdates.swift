import AxoDaemonManager
import Foundation
import Observation
import OSLog

/// One opt-in and one owned install attempt. Revocation is checked again at atomic replacement.
@MainActor
@Observable
final class AppAutomaticUpdates {
  static let enabledKey = "upgrade.automaticInstallation.v1"
  static let retryInterval: TimeInterval = 15 * 60

  typealias Authorization = @MainActor @Sendable () throws -> Void
  /// Return only after verified replacement commits. Authorize in the same main-actor turn
  /// as the atomic swap; never throw cancellation after a committed replacement.
  typealias Install = @MainActor (PublishedBuild, @escaping Authorization) async throws -> Int

  private(set) var isEnabled: Bool
  private(set) var isInstalling = false
  private(set) var failure: String?
  private let defaults: UserDefaults
  private let now: () -> Date
  private var consent = UUID()
  private var attemptedAt: Date?
  private var task: Task<Void, Never>?
  private let logger = Logger(subsystem: "dev.leostera.axo", category: "upgrade")

  init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
    self.defaults = defaults
    self.now = now
    isEnabled = defaults.bool(forKey: Self.enabledKey)
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    consent = UUID()
    attemptedAt = nil
    failure = nil
    if !enabled { task?.cancel() }
    // The task/slot stays owned until the actual installer retires, even after cancellation.
  }

  func reportRestartFailure(_ message: String) {
    failure = "The update is installed, but Axo could not restart. Use Check for Updates to retry. \(message)"
  }

  /// The caller supplies only a fresh, eligible published candidate, never a cached/local build.
  @discardableResult
  func start(
    _ release: PublishedBuild, install: @escaping Install,
    didInstall: @escaping @MainActor (Int) -> Void, didFinish: @escaping @MainActor () -> Void
  ) -> Bool {
    guard isEnabled, !isInstalling,
      AppUpdateReminder.mayInstallAutomatically(build: release.build, defaults: defaults, now: now()),
      attemptedAt.map({ now().timeIntervalSince($0) >= Self.retryInterval }) ?? true else { return false }
    let admittedConsent = consent
    attemptedAt = now()
    isInstalling = true
    failure = nil
    logger.info("event=upgrade.automatic_started build=\(release.build, privacy: .public)")
    task = Task {
      defer {
        task = nil
        isInstalling = false
        didFinish()
      }
      do {
        let build = try await install(release) { [self] in
          try Task.checkCancellation()
          guard isEnabled, consent == admittedConsent,
            AppUpdateReminder.mayInstallAutomatically(build: release.build, defaults: defaults, now: now())
          else { throw CancellationError() }
        }
        // Success means replacement committed. Never cancel handover after this point.
        didInstall(build)
      } catch is CancellationError {
        logger.info("event=upgrade.automatic_cancelled build=\(release.build, privacy: .public)")
      } catch {
        if Task.isCancelled || !isEnabled || consent != admittedConsent {
          logger.info("event=upgrade.automatic_cancelled build=\(release.build, privacy: .public)")
        } else {
          attemptedAt = now()
          failure = error.localizedDescription
          logger.error("event=upgrade.automatic_failed build=\(release.build, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
        }
      }
    }
    return true
  }
}
