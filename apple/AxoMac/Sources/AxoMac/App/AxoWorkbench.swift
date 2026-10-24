import AxoDaemonManager
import AxoRPC
import Combine
import Foundation

/// App-lifetime coordination between the daemon connection, the session catalog and Ghostty
/// surfaces. Created once per process, so opening, closing or duplicating windows never starts
/// duplicate loops; views only render state and forward user intent.
@MainActor
final class AxoWorkbench {
  let sessions: TerminalSessionsModel
  let ghostty: GhosttyRuntime
  private let catalogSync: TerminalCatalogSync?
  private var subscriptions: Set<AnyCancellable> = []
  private var focusTask: Task<Void, Never>?
  private var isConnected = false

  /// - Parameter daemonIsRunning: whether Axod is reachable. UI fixtures pass a constant `true`.
  init(
    sessions: TerminalSessionsModel,
    ghostty: GhosttyRuntime,
    daemonIsRunning: AnyPublisher<Bool, Never>
  ) {
    self.sessions = sessions
    self.ghostty = ghostty
    catalogSync = sessions.catalogClient.map {
      TerminalCatalogSync(sessions: sessions, client: $0)
    }

    daemonIsRunning
      .removeDuplicates()
      .sink { [weak self] in self?.setConnected($0) }
      .store(in: &subscriptions)
    // Reconcile after the catalog publishes, so surfaces track daemon truth, not view lifetime.
    sessions.$sessions
      .sink { [weak self] sessions in
        guard let self, self.isConnected else { return }
        self.ghostty.reconcileSurfaces(with: sessions.flatMap(\.shells))
      }
      .store(in: &subscriptions)
    sessions.$focusedShellID
      .removeDuplicates()
      .sink { [weak self] in self?.focus($0) }
      .store(in: &subscriptions)
  }

  convenience init(
    sessions: TerminalSessionsModel, ghostty: GhosttyRuntime, daemon: DaemonController
  ) {
    self.init(
      sessions: sessions,
      ghostty: ghostty,
      daemonIsRunning: daemon.$status
        .map { if case .running = $0 { true } else { false } }
        .eraseToAnyPublisher())
  }

  private func setConnected(_ connected: Bool) {
    isConnected = connected
    if connected {
      catalogSync?.start()
    } else {
      catalogSync?.stop()
      ghostty.reconcileSurfaces(with: [])
    }
  }

  /// Moves keyboard focus to the model's focused pane. The surface may not be in a key window
  /// yet (creation, window ordering), so retry briefly; a newer focus request cancels this one.
  private func focus(_ shellID: ShellID?) {
    focusTask?.cancel()
    ghostty.setFocusedShellID(shellID)
    guard let shellID else { return }
    focusTask = Task { [weak self] in
      for _ in 0..<40 {
        guard let self, !Task.isCancelled else { return }
        if self.ghostty.focusSurface(for: shellID) { return }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
  }
}
