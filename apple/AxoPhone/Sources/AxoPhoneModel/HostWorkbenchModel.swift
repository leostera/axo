import AxoClient
import AxoProtocol
import Foundation
import Observation

/// Where a Session's stored conversation comes from: the relay, over HTTPS.
public protocol PiHistoryLoading: Sendable {
  func piEvents(of host: RemoteHostRef, session: SessionID, after cursor: Int64, limit: Int) async throws -> PiEventPage
}

extension AccountClient: PiHistoryLoading {}

/// One host opened on the phone: its Sessions, whether it is online, and the live text of its
/// terminals. Everything comes from the relay's snapshots and events; nothing is stored here.
@MainActor
@Observable
public final class HostWorkbenchModel {
  public let hostLabel: String
  public let reference: RemoteHostRef
  public private(set) var status: RemoteHostStatus
  public private(set) var sessions: [RemoteSession]
  public private(set) var transcripts: [ShellID: PlainTerminalText] = [:]
  /// What each Session's agent has said, from stored history plus what has happened since.
  public private(set) var chats: [SessionID: ChatTranscript] = [:]
  public private(set) var historyStates: [SessionID: HistoryState] = [:]
  public enum HistoryState: Equatable, Sendable {
    case loading
    case loaded
    /// The stored history is longer than what was read; the newest part is missing.
    case truncated
    case failed(String)
  }

  /// Most pages read for one Session (50 events each); a conversation longer than that shows its start.
  static let maximumHistoryPages = 20

  public var selectedSessionID: SessionID?
  /// The last problem, for the screen to show; cleared by the next successful action.
  public private(set) var failure: String?

  private let connection: HostConnection
  private let history: any PiHistoryLoading
  private let account: AccountSession
  private var eventTask: Task<Void, Never>?
  private var nextInput: [ShellID: UInt64] = [:]
  private var lastOutput: [ShellID: UInt64] = [:]

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

  /// The terminal that gets typing: the Session's first.
  public var focusedShell: ShellID? { selectedSession?.shells.first?.shellId }

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
      let removedShells = sessions.first { $0.sessionId == id }?.shells.map(\.shellId) ?? []
      sessions.removeAll { $0.sessionId == id }
      for shell in removedShells { forget(shell) }
      chats[id] = nil
      historyStates[id] = nil
      if selectedSessionID == id { selectedSessionID = sessions.first?.sessionId }
    case .shellActivity:
      break
    case .terminalOutput(_, _, let shell, let sequence, let data):
      // The relay may repeat a frame after a resync; text is only ever appended once.
      if let last = lastOutput[shell], sequence <= last { return }
      lastOutput[shell] = sequence
      transcripts[shell, default: PlainTerminalText()].append(data)
    case .piEvent(_, let id, let record):
      chats[id, default: ChatTranscript()].apply(record)
    }
  }

  /// Reads a Session's stored conversation and puts it in front of what arrived live.
  public func loadHistory(of id: SessionID) async {
    guard historyStates[id] != .loading else { return }
    historyStates[id] = .loading
    var records: [PiEventRecord] = []
    var cursor: Int64 = 0
    var more = true
    do {
      for _ in 0..<Self.maximumHistoryPages where more {
        let page = try await history.piEvents(of: reference, session: id, after: cursor, limit: 50)
        records.append(contentsOf: page.events.map(\.record))
        if let next = page.next { cursor = next } else { more = false }
      }
    } catch is CancellationError {
      historyStates[id] = nil
      return
    } catch {
      account.noteFailure(error)
      historyStates[id] = .failed(error.localizedDescription)
      return
    }
    chats[id, default: ChatTranscript()].merge(history: records)
    historyStates[id] = more ? .truncated : .loaded
  }

  private func forget(_ shell: ShellID) {
    transcripts[shell] = nil
    nextInput[shell] = nil
    lastOutput[shell] = nil
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

  /// Types `text` into the focused terminal.
  public func send(_ text: String) async {
    guard let session = selectedSession, let shell = focusedShell, !text.isEmpty else { return }
    let sequence = nextInput[shell, default: 0]
    nextInput[shell] = sequence + 1
    await attempt {
      try await connection.sendInput(Data(text.utf8), to: shell, in: session.sessionId, sequence: sequence)
    }
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
