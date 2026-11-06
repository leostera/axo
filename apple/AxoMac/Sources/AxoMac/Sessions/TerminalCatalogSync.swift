import AxoProtocol
import Foundation

/// Keeps `TerminalSessionsModel` synchronized with Axod through one catalog subscription.
///
/// Subscribes before listing so no change between the listing and the first poll is lost, then
/// applies events as they arrive. A lagged stream, a daemon restart or any transport failure
/// leads to a fresh subscription and a full listing, with bounded backoff. There is no periodic
/// polling: an idle catalog costs one long-poll request per `AxodConnection.eventPollTimeout`.
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

  /// Stops the stream. The catalog is no longer live: a `.live` left from this Axod must not
  /// stand for the next one (the splash would reveal the terminal before it is connected).
  func stop() {
    task?.cancel()
    task = nil
    sessions.setCatalogConnection(.connecting)
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
        await sessions.elicitations.refresh()
        await remoteAccess?.refresh()
        // Live only once Axod has finished starting: asked after subscribing, so a
        // `daemon.ready` sent since is in the stream below.
        var axodReady = try await client.health().ready
        if axodReady { sessions.setCatalogConnection(.live) }
        backoff = minimumBackoff
        consecutiveFailures = 0
        streaming: while !Task.isCancelled {
          for event in try await client.nextEvents(for: opened) {
            if case .daemonReady = event, !axodReady {
              axodReady = true
              sessions.setCatalogConnection(.live)
            }
            if case .relayStatus(let status) = event {
              remoteAccess?.apply(status)
            } else if sessions.elicitations.apply(event) {
              continue
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
