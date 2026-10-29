import AxoProtocol
import Foundation

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

/// How the sidebar lists Sessions: grouped under their Workspaces, or one flat list by recent
/// activity.
enum SidebarMode: String, CaseIterable, Sendable {
  case workspaces
  case recent
}

/// The recent-activity order: the Session whose agent or user last finished a message first.
///
/// Activity is a completed message (Axod's `lastMessageAt`), not terminal output or streaming,
/// so Sessions move when a turn produces something rather than on every token. A Session with
/// no messages yet counts from its creation, so a new Session starts at the top.
enum SessionActivityOrder {
  /// When `session` was last active, in Unix seconds; 0 when Axod reports neither time.
  static func lastActivity(of session: TerminalSession) -> Int64 {
    max(session.lastMessageAt ?? 0, session.createdAt ?? 0)
  }

  /// Newest activity first; ties go to the newer Session.
  static func sorted(_ sessions: [TerminalSession]) -> [TerminalSession] {
    sessions.sorted { left, right in
      let (leftActivity, rightActivity) = (lastActivity(of: left), lastActivity(of: right))
      return leftActivity != rightActivity ? leftActivity > rightActivity : left.id > right.id
    }
  }

  /// `live` shown in the order `held` remembers, so rows don't move while the pointer is over
  /// the list. Closed Sessions drop out; Sessions opened since go first, in `live` order.
  static func holding(_ held: [SessionID]?, live: [TerminalSession]) -> [TerminalSession] {
    guard let held else { return live }
    let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
    let heldIDs = Set(held)
    return live.filter { !heldIDs.contains($0.id) } + held.compactMap { byID[$0] }
  }

  /// A short age for a row: "now", "5m", "3h", "2d", "4w".
  static func age(of timestamp: Int64, now: Date) -> String {
    let elapsed = max(0, Int64(now.timeIntervalSince1970) - timestamp)
    switch elapsed {
    case ..<60: return "now"
    case ..<3_600: return "\(elapsed / 60)m"
    case ..<86_400: return "\(elapsed / 3_600)h"
    case ..<604_800: return "\(elapsed / 86_400)d"
    default: return "\(elapsed / 604_800)w"
    }
  }
}
