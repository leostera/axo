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

  public var selectedSessionID: SessionID?
  /// The last problem, for the screen to show; cleared by the next successful action.
  public private(set) var failure: String?

  private let connection: HostConnection
  private let history: any PiHistoryLoading
  private let account: AccountSession
  private var eventTask: Task<Void, Never>?

  public init(host: RemoteHost, connection: HostConnection, history: any PiHistoryLoading, account: AccountSession) {
    hostLabel = host.label
    reference = host.reference
    status = host.status
    let ordered = host.sessions.sorted { $0.sessionId < $1.sessionId }
    sessions = ordered
    selectedSessionID = ordered.first?.sessionId
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
      _ = try await connection.negotiate()
      try await connection.subscribe()
    } catch {
      fail(error)
      return
    }
    failure = nil
    let events = connection.events
    eventTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        self.apply(event)
      }
    }
  }

  public func stop() {
    eventTask?.cancel()
    eventTask = nil
    Task { [connection] in await connection.disconnect() }
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
      if selectedSessionID == nil { selectedSessionID = session.sessionId }
    case .sessionRemoved(_, let id):
      sessions.removeAll { $0.sessionId == id }
      chats[id] = nil
      historyStates[id] = nil
      if selectedSessionID == id { selectedSessionID = sessions.first?.sessionId }
    case .shellActivity, .terminalOutput:
      // The phone follows Pi, not terminals.
      break
    case .piEvent(_, let id, let record):
      chats[id, default: ChatTranscript()].apply(record)
    }
  }

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
    chats[id, default: ChatTranscript()].merge(history: stored.records)
    historyStates[id] = .loaded(events: stored.records.count, hasOlder: stored.olderCursor != nil)
  }

  // MARK: - Actions

  public func createSession() async {
    await attempt {
      let session = try await connection.createSession()
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

  /// Sends a prompt to the selected Session's Pi. Pi's own `message.end` brings it back into the
  /// conversation, so nothing is added here. Returns whether the host accepted it.
  public func sendPrompt(_ text: String) async -> Bool {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let session = selectedSession, !prompt.isEmpty else { return false }
    var accepted = false
    await attempt {
      try await connection.promptPi(in: session.sessionId, text: prompt)
      accepted = true
    }
    return accepted
  }

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
