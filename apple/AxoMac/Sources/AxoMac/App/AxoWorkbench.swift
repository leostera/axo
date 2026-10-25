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
  let remoteAccess: RemoteAccessModel
  private let catalogSync: TerminalCatalogSync?
  private var observations: [ObservationLoop] = []
  private let stallMonitor = MainThreadStallMonitor()
  private var isConnected = false

  /// - Parameters:
  ///   - daemonIsRunning: whether Axod is reachable, read under observation tracking. UI
  ///     fixtures pass `{ true }`.
  ///   - daemonUnreachable: called when the catalog stream keeps failing, so the daemon owner
  ///     can re-verify health.
  init(
    sessions: TerminalSessionsModel,
    ghostty: GhosttyRuntime,
    daemonIsRunning: @escaping @MainActor () -> Bool,
    daemonUnreachable: @escaping @MainActor () -> Void = {}
  ) {
    self.sessions = sessions
    self.ghostty = ghostty
    let remoteAccess = RemoteAccessModel(client: sessions.settingsClient)
    self.remoteAccess = remoteAccess
    catalogSync = sessions.catalogClient.map {
      TerminalCatalogSync(
        sessions: sessions, remoteAccess: remoteAccess, client: $0,
        onUnreachable: daemonUnreachable)
    }

    stallMonitor.start()
    observations = [
      ObservationLoop.observe(daemonIsRunning) { [weak self] in self?.setConnected($0) },
      // Surfaces track daemon truth, not view lifetime.
      ObservationLoop.observe({ sessions.shellsByID }) { [weak self] shells in
        guard let self, self.isConnected else { return }
        self.ghostty.reconcileSurfaces(with: Array(shells.values))
      },
      ObservationLoop.observe({ sessions.focusedShellID }) { [weak self] in self?.focus($0) },
    ]
  }

  private func setConnected(_ connected: Bool) {
    isConnected = connected
    if connected {
      catalogSync?.start()
      ghostty.reconcileSurfaces(with: Array(sessions.shellsByID.values))
    } else {
      catalogSync?.stop()
      remoteAccess.reset()
      ghostty.reconcileSurfaces(with: [])
    }
  }

  /// Moves keyboard focus to the model's focused pane. The surface defers the responder change
  /// until it is in a window, so there is nothing to retry here; surfaces created later request
  /// focus from their representable.
  private func focus(_ shellID: ShellID?) {
    ghostty.setFocusedShellID(shellID)
    guard let shellID else { return }
    ghostty.surfaces.requestFocus(for: shellID)
  }
}
