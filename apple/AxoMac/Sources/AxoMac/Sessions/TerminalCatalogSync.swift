import AxoRPC
import Foundation

/// Keeps `TerminalSessionsModel` synchronized with Axod through one catalog subscription.
///
/// Subscribes before listing so no change between the listing and the first poll is lost, then
/// applies events as they arrive. A lagged stream, a daemon restart or any transport failure
/// leads to a fresh subscription and a full listing, with bounded backoff. There is no periodic
/// polling: an idle catalog costs one long-poll request per `UnixSocketAxodClient.eventPollTimeout`.
@MainActor
final class TerminalCatalogSync {
  private let sessions: TerminalSessionsModel
  private let client: AxodClient
  private let minimumBackoff: Duration
  private let maximumBackoff: Duration
  private var task: Task<Void, Never>?

  init(
    sessions: TerminalSessionsModel,
    client: AxodClient,
    minimumBackoff: Duration = .milliseconds(250),
    maximumBackoff: Duration = .seconds(5)
  ) {
    self.sessions = sessions
    self.client = client
    self.minimumBackoff = minimumBackoff
    self.maximumBackoff = maximumBackoff
  }

  var isRunning: Bool { task != nil }

  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in await self?.run() }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private func run() async {
    var backoff = minimumBackoff
    while !Task.isCancelled {
      var subscription: TerminalSubscriptionID?
      do {
        let opened = try await client.subscribeToCatalog()
        subscription = opened
        await sessions.resynchronize()
        backoff = minimumBackoff
        while !Task.isCancelled {
          guard let event = try await client.nextEvent(for: opened) else { continue }
          if await !sessions.apply(event) { break }  // Lagged: resubscribe and relist.
        }
      } catch {
        guard !Task.isCancelled else { break }
        try? await Task.sleep(for: backoff)
        backoff = min(backoff * 2, maximumBackoff)
      }
      if let subscription {
        // Best effort; Axod also reclaims subscriptions nobody polls.
        try? await client.unsubscribe(subscription)
      }
    }
  }
}
