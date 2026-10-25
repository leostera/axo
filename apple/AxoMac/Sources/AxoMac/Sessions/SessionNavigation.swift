import AxoRPC

/// Most-recently-focused Sessions, newest first, bounded so long-running apps don't grow it.
struct RecentSessions: Equatable {
  static let capacity = 128
  private(set) var ids: [SessionID] = []

  mutating func remember(_ sessionID: SessionID) {
    ids.removeAll { $0 == sessionID }
    ids.insert(sessionID, at: 0)
    if ids.count > Self.capacity { ids.removeLast(ids.count - Self.capacity) }
  }

  mutating func forget(_ sessionID: SessionID) {
    ids.removeAll { $0 == sessionID }
  }
}

/// How the sidebar groups Sessions. Every open Session appears exactly once: under its
/// Workspace when that Workspace is listed, otherwise with the standalone Sessions. A Session
/// can arrive before its Workspace does (the Workspace list is refetched after
/// `workspace.changed`), and it must stay visible and navigable meanwhile.
struct SidebarSections: Equatable {
  /// Sessions of each listed Workspace, in catalog order.
  let sessionsByWorkspace: [String: [TerminalSession]]
  /// Standalone Sessions and those whose Workspace is not listed, in catalog order.
  let ungrouped: [TerminalSession]
  /// Workspace groups in Workspace order, then the ungrouped Sessions.
  let ordered: [TerminalSession]

  init(sessions: [TerminalSession], workspaces: [WorkspaceRecord]) {
    let listed = Set(workspaces.map(\.workspaceId))
    var byWorkspace: [String: [TerminalSession]] = [:]
    var ungrouped: [TerminalSession] = []
    for session in sessions {
      if let workspaceID = session.workspaceId, listed.contains(workspaceID) {
        byWorkspace[workspaceID, default: []].append(session)
      } else {
        ungrouped.append(session)
      }
    }
    sessionsByWorkspace = byWorkspace
    self.ungrouped = ungrouped
    ordered = workspaces.flatMap { byWorkspace[$0.workspaceId] ?? [] } + ungrouped
  }

  func sessions(in workspaceID: String) -> [TerminalSession] {
    sessionsByWorkspace[workspaceID] ?? []
  }
}

/// Pure ordering and selection policy for the sidebar and keyboard navigation.
enum SessionNavigation {

  /// The index one step from `currentIndex`, wrapping. With no current item, `next` lands on the
  /// first item and `previous` on the last.
  static func adjacentIndex(
    from currentIndex: Int?, count: Int, direction: TerminalNavigationDirection
  ) -> Int? {
    guard count > 0 else { return nil }
    let start = currentIndex ?? (direction == .next ? count - 1 : 0)
    return (start + direction.rawValue + count) % count
  }

  /// The Session to show after `closed` goes away: the most recent Session in the same
  /// Workspace, then Axod's replacement, then any Session in the same Workspace, then any.
  static func successor(
    afterClosing closed: TerminalSession,
    in sessions: [TerminalSession],
    recent: RecentSessions,
    replacement: TerminalSession? = nil
  ) -> SessionID? {
    let remaining = sessions.filter { $0.id != closed.id }
    func isOpenSibling(_ id: SessionID) -> Bool {
      remaining.contains { $0.id == id && $0.workspaceId == closed.workspaceId }
    }
    if let recentSibling = recent.ids.first(where: isOpenSibling) { return recentSibling }
    if let replacement, isOpenSibling(replacement.id) { return replacement.id }
    return remaining.first(where: { $0.workspaceId == closed.workspaceId })?.id
      ?? remaining.first?.id
  }
}
