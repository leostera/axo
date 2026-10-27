import AxoClient
import AxoProtocol
import Foundation
import Observation

/// Where a Session's stored conversation comes from: the relay, over HTTPS.
public protocol PiHistoryLoading: Sendable {
  func piEvents(of host: RemoteHostRef, session: SessionID, before cursor: Int64, limit: Int) async throws -> PiEventPage
}

extension AccountClient: PiHistoryLoading {}

/// One host opened on the phone: its Sessions, whether it is online, and what Pi says in each.
/// Everything comes from the relay's snapshots and events; nothing is stored here.
@MainActor
@Observable
public final class HostWorkbenchModel {
  public let hostLabel: String
  public let reference: RemoteHostRef
  public private(set) var status: RemoteHostStatus
  public private(set) var sessions: [RemoteSession]
  /// What each Session's agent has said, from stored history plus what has happened since.
  public private(set) var chats: [SessionID: ChatTranscript] = [:]
  public private(set) var historyStates: [SessionID: HistoryState] = [:]
  public enum HistoryState: Equatable, Sendable {
    case loading
    /// Read this many stored events (messages are only some of them); `hasOlder` says more are stored.
    case loaded(events: Int, hasOlder: Bool)
    case loadingOlder(events: Int)
    case failed(String)
  }

  /// Events per page; pages are read newest first and only as a conversation is scrolled back.
  static let historyPageSize = 50

  private struct StoredHistory {
    /// Oldest first.
    var records: [PiEventRecord]
    /// Where the next older page starts; nil when this is the beginning.
    var olderCursor: Int64?
  }
  private var storedHistory: [SessionID: StoredHistory] = [:]

  /// A message the phone sent that the agent has not recorded yet, shown at the end of its chat
  /// until the agent's own record of it arrives.
  public struct PendingPrompt: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
      /// On its way to the Mac.
      case sending
      /// The Mac took it; the agent will record it shortly.
      case sent
      /// The Mac took it while the agent was busy; it is answered after the current reply.
      case queued
      /// The connection ended before the Mac answered: it may or may not have arrived. It is not
      /// sent again on its own (that could send it twice); the person checks the chat first.
      case uncertain
    }

    public let id: UUID
    public let text: String
    public fileprivate(set) var state: State
  }

  /// Per chat, oldest first.
  public private(set) var pendingPrompts: [SessionID: [PendingPrompt]] = [:]

  /// Chats whose reply the person asked to stop, until Pi says it has.
  public private(set) var stopping: Set<SessionID> = []

  /// Whether the live connection to this Mac is up.
  public enum Link: Equatable, Sendable {
    /// Not started yet.
    case idle
    case connected
    /// The connection dropped; trying again, with growing pauses.
    case reconnecting
    /// The app is in the background: no connection on purpose.
    case suspended
  }
  public private(set) var link: Link = .idle
  /// The Mac's Workspaces as last read, so the menu can show the ones with no chats yet.
  public private(set) var workspaceList: [RemoteWorkspace] = []

  /// The chat on screen. Nothing selects one on its own: the person (or a new chat) does.
  public var selectedSessionID: SessionID?
  /// The last problem, for the screen to show; cleared by the next successful action.
  public private(set) var failure: String?

  private let connection: HostConnection
  private let history: any PiHistoryLoading
  private let account: AccountSession
  private var eventTask: Task<Void, Never>?
  private var lossTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  /// Pauses between reconnection attempts; tests make them short.
  let reconnectDelays: [Duration]

  public init(
    host: RemoteHost, connection: HostConnection, history: any PiHistoryLoading, account: AccountSession,
    reconnectDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(15)]
  ) {
    self.reconnectDelays = reconnectDelays
    hostLabel = host.label
    reference = host.reference
    status = host.status
    let ordered = host.sessions.sorted { $0.sessionId < $1.sessionId }
    sessions = ordered
    self.connection = connection
    self.history = history
    self.account = account
  }

  public var selectedSession: RemoteSession? {
    sessions.first { $0.sessionId == selectedSessionID }
  }

  /// Whether the model is connected and following the host's events.
  public var isFollowing: Bool { eventTask != nil }

  /// Connects, subscribes, and keeps applying the host's events until `stop()`.
  public func start() async {
    guard eventTask == nil else { return }
    do {
      try await connection.subscribe()
    } catch {
      fail(error)
      return
    }
    failure = nil
    link = .connected
    let events = connection.events
    eventTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        self.apply(event)
      }
    }
    let losses = connection.connectionLost
    lossTask = Task { [weak self] in
      for await _ in losses {
        guard let self else { return }
        self.connectionLost()
      }
    }
    Task { await refreshWorkspaces() }
  }

  /// Reads the Mac's Workspaces for the menu; a failure leaves the last list and says nothing.
  public func refreshWorkspaces() async {
    if let found = try? await connection.workspaces() { workspaceList = found }
  }

  public func stop() {
    eventTask?.cancel()
    eventTask = nil
    lossTask?.cancel()
    lossTask = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    link = .idle
    Task { [connection] in await connection.disconnect() }
  }

  /// The app went to the background: let the connection go rather than have it die unnoticed.
  public func suspend() {
    guard isFollowing, link != .suspended else { return }
    reconnectTask?.cancel()
    reconnectTask = nil
    link = .suspended
    Task { [connection] in await connection.disconnect() }
  }

  /// The app is back: connect again and catch up on what was missed.
  public func resume() {
    guard isFollowing, link == .suspended || link == .reconnecting else { return }
    reconnect()
  }

  private func connectionLost() {
    guard link == .connected else { return }
    reconnect()
  }

  /// Subscribes again until it works, then reads what was said meanwhile. Events that arrived
  /// while the connection was down are gone; the stored history has them.
  private func reconnect() {
    link = .reconnecting
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self, connection, reconnectDelays] in
      var attempt = 0
      while !Task.isCancelled {
        do {
          try await connection.reconnect()
          guard let self, !Task.isCancelled else { return }
          self.link = .connected
          self.failure = nil
          await self.catchUp()
          return
        } catch is CancellationError {
          return
        } catch {
          if let self, self.account.noteFailure(error) { return }
          let delay = reconnectDelays[min(attempt, reconnectDelays.count - 1)]
          attempt += 1
          try? await Task.sleep(for: delay)
        }
      }
    }
  }

  /// After a gap: the open chat reads its newest history again (merging never repeats a
  /// message), the others will when opened, and whether Pi is working comes from the Mac's
  /// last report of each Session.
  private func catchUp() async {
    for id in historyStates.keys where id != selectedSessionID { historyStates[id] = nil }
    for session in sessions {
      if let working = session.status.map({ $0 == .working }), chats[session.sessionId] != nil {
        chats[session.sessionId]?.settle(working: working)
        if !working { stopping.remove(session.sessionId) }
      }
    }
    Task { await refreshWorkspaces() }
    if let id = selectedSessionID { await loadHistory(of: id) }
  }

  /// The account's listing of this Mac was read again: its Sessions as listed replace what the
  /// events said, which may have missed changes while the connection was down.
  public func adopt(listing host: RemoteHost) {
    guard host.reference == reference else { return }
    status = host.status
    sessions = host.sessions.sorted { $0.sessionId < $1.sessionId }
    if let selected = selectedSessionID, !sessions.contains(where: { $0.sessionId == selected }) {
      selectedSessionID = nil
    }
  }

  // MARK: - Events

  func apply(_ event: RemoteHostEvent) {
    guard event.host == reference else { return }
    switch event {
    case .presence(_, let newStatus):
      status = newStatus
    case .sessionSnapshot(_, let session):
      if let index = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
        sessions[index] = session
      } else {
        sessions.append(session)
        sessions.sort { $0.sessionId < $1.sessionId }
      }
    case .sessionRemoved(_, let id):
      sessions.removeAll { $0.sessionId == id }
      chats[id] = nil
      historyStates[id] = nil
      pendingPrompts[id] = nil
      if selectedSessionID == id { selectedSessionID = nil }
    case .shellActivity, .terminalOutput:
      // The phone follows Pi, not terminals.
      break
    case .piEvent(_, let id, let record):
      changeChat(id) { $0.apply(record) }
    }
  }

  #if DEBUG
    /// For the simulator preview only: plays events as if the Mac had sent them.
    public func playForPreview(_ records: [PiEventRecord], in id: SessionID) {
      for record in records { apply(.piEvent(host: reference, sessionID: id, event: record)) }
    }

    /// For the simulator preview only: as if a stop had been asked for.
    public func markStoppingForPreview(_ id: SessionID) { stopping.insert(id) }
  #endif

  /// Reads the newest page of a Session's stored conversation and puts it in front of what arrived
  /// live. Older pages are read only when asked for, by `loadOlderHistory`.
  public func loadHistory(of id: SessionID) async {
    if case .loading = historyStates[id] { return }
    if case .loadingOlder = historyStates[id] { return }
    historyStates[id] = .loading
    do {
      let page = try await history.piEvents(of: reference, session: id, before: 0, limit: Self.historyPageSize)
      let records = Array(page.events.map(\.record).reversed())
      storedHistory[id] = StoredHistory(records: records, olderCursor: page.next)
      showStoredHistory(of: id)
    } catch is CancellationError {
      historyStates[id] = nil
    } catch {
      account.noteFailure(error)
      historyStates[id] = .failed(error.localizedDescription)
    }
  }

  /// Reads the page before the oldest one already shown. Does nothing when there is none.
  public func loadOlderHistory(of id: SessionID) async {
    guard case .loaded(let events, true) = historyStates[id],
      let stored = storedHistory[id], let cursor = stored.olderCursor
    else { return }
    historyStates[id] = .loadingOlder(events: events)
    do {
      let page = try await history.piEvents(of: reference, session: id, before: cursor, limit: Self.historyPageSize)
      storedHistory[id] = StoredHistory(
        records: Array(page.events.map(\.record).reversed()) + stored.records, olderCursor: page.next)
      showStoredHistory(of: id)
    } catch is CancellationError {
      historyStates[id] = .loaded(events: events, hasOlder: true)
    } catch {
      account.noteFailure(error)
      historyStates[id] = .loaded(events: events, hasOlder: true)
      failure = error.localizedDescription
    }
  }

  private func showStoredHistory(of id: SessionID) {
    guard let stored = storedHistory[id] else { return }
    changeChat(id) { $0.merge(history: stored.records) }
    historyStates[id] = .loaded(events: stored.records.count, hasOlder: stored.olderCursor != nil)
  }

  // MARK: - Actions

  /// The Workspaces a chat can start in. A chat is a Session in a Workspace, which runs Pi in the
  /// Workspace's directory; a Session made outside one is a bare terminal with no Pi.
  public func workspaces() async -> [RemoteWorkspace]? {
    var found: [RemoteWorkspace]?
    await attempt { found = try await connection.workspaces() }
    if let found { workspaceList = found }
    return found
  }

  /// Starts a chat in `workspace` and opens it.
  public func createChat(in workspace: UUID) async {
    await attempt {
      let session = try await connection.createSession(inWorkspace: workspace)
      apply(.sessionSnapshot(host: reference, session: session))
      selectedSessionID = session.sessionId
    }
  }

  public func closeSession(_ id: SessionID) async {
    await attempt {
      let replacement = try await connection.closeSession(id)
      apply(.sessionRemoved(host: reference, sessionID: id))
      if let replacement { apply(.sessionSnapshot(host: reference, session: replacement)) }
    }
  }

  public func renameSession(_ id: SessionID, to name: String) async {
    await attempt { try await connection.renameSession(id, to: name) }
  }

  /// How sending a message went.
  public enum PromptOutcome: Equatable, Sendable {
    case accepted
    /// Not sent (or refused): nothing reached Pi, so the words can go back in the box.
    case notSent
    /// The connection ended before the Mac answered; the message stays, marked uncertain.
    case uncertain
  }

  /// Sends a message to the selected chat. It shows as pending until the agent's own record of it
  /// (`message.end`) arrives; one that was not sent disappears.
  public func sendPrompt(_ text: String) async -> PromptOutcome {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let session = selectedSession, !prompt.isEmpty else { return .notSent }
    let id = session.sessionId
    let pending = PendingPrompt(id: UUID(), text: prompt, state: .sending)
    pendingPrompts[id, default: []].append(pending)
    let outcome: PromptOutcome
    do {
      try await connection.promptPi(in: id, text: prompt)
      failure = nil
      outcome = .accepted
    } catch is CancellationError {
      outcome = .notSent
    } catch {
      account.noteFailure(error)
      outcome = Self.deliveryUncertain(error) ? .uncertain : .notSent
      failure = outcome == .uncertain
        ? "The connection to \(hostLabel) dropped while sending. Check the chat before sending again."
        : Self.notSentReason(error, host: hostLabel)
    }
    guard let index = pendingPrompts[id]?.firstIndex(where: { $0.id == pending.id }) else { return outcome }
    switch outcome {
    case .accepted:
      pendingPrompts[id]?[index].state = chats[id]?.activity == .working ? .queued : .sent
    case .uncertain:
      pendingPrompts[id]?[index].state = .uncertain
    case .notSent:
      removePending(pending.id, in: id)
    }
    return outcome
  }

  /// Takes a message marked uncertain off the screen, once the person has checked.
  public func dismissPending(_ pendingID: UUID, in id: SessionID) {
    removePending(pendingID, in: id)
  }

  private func removePending(_ pendingID: UUID, in id: SessionID) {
    pendingPrompts[id]?.removeAll { $0.id == pendingID }
    if pendingPrompts[id]?.isEmpty == true { pendingPrompts[id] = nil }
  }

  /// Whether the request may have reached the Mac although no answer came back: it was written
  /// and then the connection ended, timed out, or the relay could not tell what happened.
  static func deliveryUncertain(_ error: Error) -> Bool {
    switch error as? AxoClientError {
    case .connectionClosed, .requestTimedOut: true
    // The relay's own "it went to the Mac, no answer came back" (axod's -32004 is "not found").
    case .serverRejected(let code, let message): code == -32004 && message.contains("reconcile")
    default: false
    }
  }

  static func notSentReason(_ error: Error, host: String) -> String {
    switch error as? AxoClientError {
    case .connectionFailed:
      "Not sent: no connection to \(host). Your message is still in the box."
    case .serverRejected(_, let message):
      "Not sent: \(message)"
    default:
      "Not sent: \(error.localizedDescription)"
    }
  }

  /// Stops the reply in progress in `id`, as Escape does on the Mac.
  public func stopReply(in id: SessionID) async {
    guard chats[id]?.activity == .working, !stopping.contains(id) else { return }
    stopping.insert(id)
    var pressed = false
    await attempt {
      try await connection.pressPiKey(.escape, in: id)
      pressed = true
    }
    if !pressed { stopping.remove(id) }
  }

  /// An answer to what Pi is asking.
  public enum Answer: Equatable, Sendable {
    case yes
    case no
    case text(String)
  }

  /// Answers Pi's question in `id`: yes is Enter, no is Escape, and words are typed and submitted
  /// as a prompt is. The question stays on screen until Pi says it is answered.
  public func answer(_ answer: Answer, in id: SessionID) async {
    guard chats[id]?.question != nil else { return }
    await attempt {
      switch answer {
      case .yes: try await connection.pressPiKey(.enter, in: id)
      case .no: try await connection.pressPiKey(.escape, in: id)
      case .text(let words): try await connection.promptPi(in: id, text: words)
      }
    }
  }

  /// Changes a chat, then retires the pending messages its newest user messages account for: the one
  /// with the same words, or else the oldest the Mac has taken (the agent records them in order).
  private func changeChat(_ id: SessionID, _ change: (inout ChatTranscript) -> Void) {
    let before = Set(chats[id]?.messages.map(\.id) ?? [])
    change(&chats[id, default: ChatTranscript()])
    if chats[id]?.activity == .idle { stopping.remove(id) }
    guard var pending = pendingPrompts[id], !pending.isEmpty, let messages = chats[id]?.messages else { return }
    // Only what came after everything already shown: an older page of history is not news.
    let start = messages.lastIndex { before.contains($0.id) }.map { $0 + 1 } ?? 0
    for message in messages[start...] where message.role == .user {
      let words = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if let match = pending.firstIndex(where: { $0.text == words }) {
        pending.remove(at: match)
      } else if let oldest = pending.firstIndex(where: { $0.state != .sending }) {
        pending.remove(at: oldest)
      }
    }
    pendingPrompts[id] = pending.isEmpty ? nil : pending
  }

  /// Shows `message` where failures are shown.
  func report(_ message: String) { failure = message }

  private func attempt(_ work: () async throws -> Void) async {
    do {
      try await work()
      failure = nil
    } catch is CancellationError {
    } catch {
      fail(error)
    }
  }

  private func fail(_ error: Error) {
    account.noteFailure(error)
    failure = error.localizedDescription
  }
}
