import AxoProtocol

/// The open Sessions as Axod last described them, plus shell membership the app has already
/// applied from command results. A pure value: `TerminalSessionsModel` holds one and projects it.
///
/// Invariant: `sessions` is in creation order (oldest first, ties by ID, as Axod lists them) with
/// no duplicate IDs, whatever order Axod or a command result delivers them in. Session IDs are
/// UUIDs and carry no order of their own.
struct SessionCatalog: Equatable {
  private(set) var sessions: [TerminalSession]

  init(_ sessions: [TerminalSession] = []) {
    // The last record for an ID wins, as it would if they arrived one at a time.
    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    self.sessions = byID.values.sorted(by: Self.isCreatedBefore)
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
    if let index = index(of: session.id) {
      guard sessions[index].createdAt != session.createdAt else {
        sessions[index] = session
        return
      }
      sessions.remove(at: index)
    }
    let position = sessions.firstIndex { Self.isCreatedBefore(session, $0) } ?? sessions.endIndex
    sessions.insert(session, at: position)
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
    sessions.firstIndex { $0.id == sessionID }
  }

  private static func isCreatedBefore(_ left: TerminalSession, _ right: TerminalSession) -> Bool {
    let (leftCreated, rightCreated) = (left.createdAt ?? 0, right.createdAt ?? 0)
    return leftCreated != rightCreated
      ? leftCreated < rightCreated : left.id.rawValue < right.id.rawValue
  }
}
