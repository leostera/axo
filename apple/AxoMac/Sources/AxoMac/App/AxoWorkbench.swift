import AxoDaemonManager
import AxoRPC
import Foundation

/// App-lifetime coordination between the daemon connection, the session catalog and Ghostty
/// surfaces. Created once per process, so opening, closing or duplicating windows never starts
/// duplicate loops; views only render state and forward user intent.
@MainActor
final class AxoWorkbench {
  let sessions: TerminalSessionsModel
  let ghostty: GhosttyRuntime
  private let catalogSync: TerminalCatalogSync?
  private var observations: [ObservationLoop] = []
  private var focusTask: Task<Void, Never>?
  private var isConnected = false

  /// - Parameter daemonIsRunning: whether Axod is reachable, read under observation tracking.
  ///   UI fixtures pass `{ true }`.
  init(
    sessions: TerminalSessionsModel,
    ghostty: GhosttyRuntime,
    daemonIsRunning: @escaping @MainActor () -> Bool
  ) {
    self.sessions = sessions
    self.ghostty = ghostty
    catalogSync = sessions.catalogClient.map {
      TerminalCatalogSync(sessions: sessions, client: $0)
    }

    observations = [
      ObservationLoop.observe(daemonIsRunning) { [weak self] in self?.setConnected($0) },
      // Surfaces track daemon truth, not view lifetime.
      ObservationLoop.observe({ sessions.sessions.flatMap(\.shells) }) { [weak self] shells in
        guard let self, self.isConnected else { return }
        self.ghostty.reconcileSurfaces(with: shells)
      },
      ObservationLoop.observe({ sessions.focusedShellID }) { [weak self] in self?.focus($0) },
    ]
  }

  private func setConnected(_ connected: Bool) {
    isConnected = connected
    if connected {
      catalogSync?.start()
      ghostty.reconcileSurfaces(with: sessions.sessions.flatMap(\.shells))
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
