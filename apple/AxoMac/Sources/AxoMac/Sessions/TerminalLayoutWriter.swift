import AxoRPC
import Foundation

/// Debounced, coalescing persistence of per-session layouts to Axod. At most one write per
/// session is in flight; newer layouts replace older unsent ones. A failed write keeps the latest
/// unsent layout so the next change retries it.
@MainActor
final class TerminalLayoutWriter {
  private let client: AxodClient?
  private let debounce: Duration
  private var pending: [Int64: SessionLayout] = [:]
  private var tasks: [Int64: Task<Void, Never>] = [:]

  /// Reports a failed write for a session that is still open.
  var onError: ((Error) -> Void)?
  /// Whether a session is still open; writes for closed sessions are dropped.
  var isSessionOpen: (Int64) -> Bool = { _ in true }

  init(client: AxodClient?, debounce: Duration = .milliseconds(150)) {
    self.client = client
    self.debounce = debounce
  }

  func schedule(_ layout: SessionLayout, for sessionID: Int64) {
    guard let client else { return }
    pending[sessionID] = layout
    guard tasks[sessionID] == nil else { return }
    tasks[sessionID] = Task { @MainActor [weak self, debounce] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: debounce)
        } catch {
          break
        }
        guard let self, let layout = self.pending.removeValue(forKey: sessionID) else { break }
        do {
          try await client.setLayout(layout, forSession: sessionID)
        } catch {
          if !Task.isCancelled, self.isSessionOpen(sessionID) {
            self.pending[sessionID] = self.pending[sessionID] ?? layout
            self.onError?(error)
          }
          break
        }
      }
      self?.tasks[sessionID] = nil
    }
  }

  func discard(sessionID: Int64) {
    pending.removeValue(forKey: sessionID)
    tasks.removeValue(forKey: sessionID)?.cancel()
  }

  /// Drops pending writes for sessions that are no longer open.
  func retain(sessionIDs openSessionIDs: Set<Int64>) {
    pending = pending.filter { openSessionIDs.contains($0.key) }
    for sessionID in Array(tasks.keys) where !openSessionIDs.contains(sessionID) {
      tasks.removeValue(forKey: sessionID)?.cancel()
    }
  }
}
