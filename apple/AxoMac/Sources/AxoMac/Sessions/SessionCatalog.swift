import AxoProtocol

/// The open Sessions as Axod last described them, plus shell membership the app has already
/// applied from command results. A pure value: `TerminalSessionsModel` holds one and projects it.
///
/// Invariant: `sessions` is sorted by ID with no duplicates, whatever order Axod or a command
/// result delivers them in.
struct SessionCatalog: Equatable {
  private(set) var sessions: [TerminalSession]

  init(_ sessions: [TerminalSession] = []) {
    // The last record for an ID wins, as it would if they arrived one at a time.
    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    self.sessions = byID.values.sorted { $0.id < $1.id }
  }

  var isEmpty: Bool { sessions.isEmpty }

  func session(for sessionID: SessionID) -> TerminalSession? {
    index(of: sessionID).map { sessions[$0] }
  }

  /// The open Session a shell belongs to.
  func session(containing shellID: ShellID) -> TerminalSession? {
    sessions.first { $0.shells.contains { $0.id == shellID } }
  }

  /// Every open shell by ID, across Sessions.
  var shellsByID: [ShellID: TerminalShell] {
    Dictionary(
      sessions.lazy.flatMap(\.shells).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
  }

  /// Inserts `session`, or replaces the record with its ID.
  mutating func upsert(_ session: TerminalSession) {
    switch search(session.id) {
    case .found(let index): sessions[index] = session
    case .insertAt(let index): sessions.insert(session, at: index)
    }
  }

  func upserting(_ session: TerminalSession) -> SessionCatalog {
    var copy = self
    copy.upsert(session)
    return copy
  }

  mutating func remove(_ sessionIDs: Set<SessionID>) {
    sessions.removeAll { sessionIDs.contains($0.id) }
  }

  func removing(_ sessionIDs: Set<SessionID>) -> SessionCatalog {
    var copy = self
    copy.remove(sessionIDs)
    return copy
  }

  /// Sets a Session's shells from a command result (a split or a close) ahead of Axod's next
  /// snapshot. Does nothing if the Session is no longer open.
  mutating func replaceShells(of sessionID: SessionID, with shells: [TerminalShell]) {
    guard let index = index(of: sessionID) else { return }
    sessions[index] = sessions[index].replacing(shells: shells)
  }

  private func index(of sessionID: SessionID) -> Int? {
    guard case .found(let index) = search(sessionID) else { return nil }
    return index
  }

  private enum SearchResult {
    case found(Int)
    case insertAt(Int)
  }

  /// Binary search over the sorted `sessions`.
  private func search(_ sessionID: SessionID) -> SearchResult {
    var low = 0
    var high = sessions.count
    while low < high {
      let middle = (low + high) / 2
      if sessions[middle].id == sessionID { return .found(middle) }
      if sessions[middle].id < sessionID { low = middle + 1 } else { high = middle }
    }
    return .insertAt(low)
  }
}
