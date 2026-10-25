import AxoProtocol
import Foundation

/// Retries recovery of unavailable Pi panes while the user preference is enabled. Each pane has at
/// most one retry loop; loops stop when the pane recovers, disappears, or the preference is
/// disabled. Recovery itself is Axod's idle-only, non-forcing `auto` restart.
@MainActor
final class AutomaticPiRestarter {
  enum Failure: Error {
    /// The running Axod lacks automatic recovery; retry slowly in case it is upgraded.
    case unsupportedAxod
  }

  var isEnabled: Bool {
    didSet {
      guard isEnabled != oldValue else { return }
      if !isEnabled { cancelAll() }
    }
  }

  /// Attempts one automatic restart of `shellID`.
  var restart: (ShellID) async throws -> Void = { _ in }
  /// Whether `shellID` is still an unavailable Pi pane.
  var needsRestart: (ShellID) -> Bool = { _ in false }

  private var loops: [ShellID: (id: UUID, task: Task<Void, Never>)] = [:]
  private let maximumBackoff: Duration
  private let unsupportedRetryDelay: Duration

  init(
    isEnabled: Bool,
    maximumBackoff: Duration = .seconds(30),
    unsupportedRetryDelay: Duration = .seconds(30)
  ) {
    self.isEnabled = isEnabled
    self.maximumBackoff = maximumBackoff
    self.unsupportedRetryDelay = unsupportedRetryDelay
  }

  func schedule(for sessions: [TerminalSession]) {
    guard isEnabled else { return }
    for shell in sessions.flatMap(\.shells)
    where shell.isPi && !shell.isAvailable && loops[shell.id] == nil {
      let id = UUID()
      let shellID = shell.id
      loops[shellID] = (id, Task { [weak self] in await self?.retry(shellID: shellID, loopID: id) })
    }
  }

  func cancel(shellID: ShellID) {
    loops.removeValue(forKey: shellID)?.task.cancel()
  }

  func cancelAll() {
    for loop in loops.values { loop.task.cancel() }
    loops.removeAll()
  }

  private func retry(shellID: ShellID, loopID: UUID) async {
    defer {
      if loops[shellID]?.id == loopID { loops.removeValue(forKey: shellID) }
    }
    var delay: Duration = .seconds(1)
    while !Task.isCancelled, isEnabled, needsRestart(shellID) {
      do {
        try await restart(shellID)
        return
      } catch Failure.unsupportedAxod {
        try? await Task.sleep(for: unsupportedRetryDelay)
      } catch {
        try? await Task.sleep(for: delay)
        delay = min(delay * 2, maximumBackoff)
      }
    }
  }
}
