import AxoProtocol
import Foundation
import OSLog

/// Tells Axod where this window draws terminals, so panes no surface shows yet (and new ones)
/// already have the grid they will be shown at. Debounced and coalescing: only the latest
/// viewport is sent, once per change, and again after every reconnect (Axod may have restarted).
@MainActor
final class ViewportReporter {
  private static let log = Logger(subsystem: "dev.leostera.axo", category: "surfaces")

  private let client: AxodClient?
  private let debounce: Duration
  private var latest: ClientViewport?
  private var sent: ClientViewport?
  private var task: Task<Void, Never>?

  /// Whether the connected Axod offers `axo.client.viewport.set`.
  var isSupported: () async throws -> Bool = { false }

  init(client: AxodClient?, debounce: Duration = .milliseconds(100)) {
    self.client = client
    self.debounce = debounce
  }

  func report(_ viewport: ClientViewport) {
    latest = viewport
    scheduleIfNeeded()
  }

  /// A new connection: Axod has not heard from this client yet.
  func reconnected() {
    sent = nil
    scheduleIfNeeded()
  }

  private func scheduleIfNeeded() {
    guard let client, latest != sent, task == nil else { return }
    task = Task { @MainActor [weak self, debounce] in
      defer { self?.task = nil }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: debounce)
        } catch {
          return
        }
        guard let self, let viewport = self.latest, viewport != self.sent else { return }
        do {
          guard try await self.isSupported() else { return }
          try await client.setViewport(viewport)
          self.sent = viewport
        } catch {
          // Panes still resize when shown; the next change or reconnect retries.
          Self.log.debug(
            "event=surface.viewport_report_failed error=\(error.localizedDescription, privacy: .public)")
          return
        }
      }
    }
  }
}
