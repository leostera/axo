import AxoProtocol
import Foundation

/// Keeps `TerminalSessionsModel` synchronized with Axod through one catalog subscription.
///
/// Subscribes before listing so no change between the listing and the first poll is lost, then
/// applies events as they arrive. A lagged stream, a daemon restart or any transport failure
/// leads to a fresh subscription and a full listing, with bounded backoff. There is no periodic
/// polling: an idle catalog costs one long-poll request per `UnixSocketAxodClient.eventPollTimeout`.
@MainActor
final class TerminalCatalogSync {
  /// Consecutive failures after which the daemon itself is re-verified.
  static let unreachableThreshold = 3

  private let sessions: TerminalSessionsModel
  private let remoteAccess: RemoteAccessModel?
  private let client: AxodClient
  private let minimumBackoff: Duration
  private let maximumBackoff: Duration
  private let onUnreachable: @MainActor () -> Void
  private var task: Task<Void, Never>?

  /// - Parameter onUnreachable: called once per outage, after `unreachableThreshold` consecutive
  ///   failures, so the daemon lifecycle owner can re-check health.
  init(
    sessions: TerminalSessionsModel,
    remoteAccess: RemoteAccessModel? = nil,
    client: AxodClient,
    minimumBackoff: Duration = .milliseconds(250),
    maximumBackoff: Duration = .seconds(5),
    onUnreachable: @escaping @MainActor () -> Void = {}
  ) {
    self.sessions = sessions
    self.remoteAccess = remoteAccess
    self.client = client
    self.minimumBackoff = minimumBackoff
    self.maximumBackoff = maximumBackoff
    self.onUnreachable = onUnreachable
  }

  var isRunning: Bool { task != nil }

  func start() {
    guard task == nil else { return }
    sessions.setCatalogConnection(.connecting)
    task = Task { [weak self] in await self?.run() }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private func run() async {
    var backoff = minimumBackoff
    var consecutiveFailures = 0
    while !Task.isCancelled {
      var subscription: TerminalSubscriptionID?
      do {
        let opened = try await client.subscribeToCatalog()
        subscription = opened
        try await sessions.resynchronize()
        await remoteAccess?.refresh()
        sessions.setCatalogConnection(.live)
        backoff = minimumBackoff
        consecutiveFailures = 0
        streaming: while !Task.isCancelled {
          for event in try await client.nextEvents(for: opened) {
            if case .relayStatus(let status) = event {
              remoteAccess?.apply(status)
            } else if await !sessions.apply(event) {
              break streaming  // Lagged: resubscribe and relist.
            }
          }
        }
      } catch {
        guard !Task.isCancelled else { break }
        consecutiveFailures += 1
        sessions.setCatalogConnection(.reconnecting(reason: error.localizedDescription))
        if consecutiveFailures == Self.unreachableThreshold { onUnreachable() }
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
