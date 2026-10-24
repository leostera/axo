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

/// Pure ordering and selection policy for the sidebar and keyboard navigation.
enum SessionNavigation {
  /// Workspace Sessions grouped in Workspace order, then standalone Sessions; each group keeps
  /// catalog order.
  static func sidebarOrder(
    _ sessions: [TerminalSession], workspaces: [WorkspaceRecord]
  ) -> [TerminalSession] {
    let byWorkspace = Dictionary(grouping: sessions.filter { $0.workspaceId != nil }) {
      $0.workspaceId!
    }
    return workspaces.flatMap { byWorkspace[$0.workspaceId] ?? [] }
      + sessions.filter { $0.workspaceId == nil }
  }

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
