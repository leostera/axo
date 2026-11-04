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

/// Which Macs' Sessions the sidebar lists, latest activity first (RFD0024).
enum SidebarMacs: Equatable, Hashable, Sendable {
  case thisMac
  /// One other Mac, by host id.
  case mac(String)
  case all

  init?(rawValue: String) {
    switch rawValue {
    case "this": self = .thisMac
    case "all": self = .all
    default:
      guard rawValue.hasPrefix("mac:") else { return nil }
      self = .mac(String(rawValue.dropFirst(4)))
    }
  }

  var rawValue: String {
    switch self {
    case .thisMac: "this"
    case .all: "all"
    case .mac(let hostID): "mac:\(hostID)"
    }
  }

  /// The Mac `hostID` names (nil for this Mac), as the sidebar lists it alone.
  init(hostID: String?) {
    self = hostID.map(SidebarMacs.mac) ?? .thisMac
  }

  /// One step through This Mac, each other Mac in `hostIDs` order, then All Macs, wrapping;
  /// nil when there is no other Mac to step to. A Mac no longer known counts as This Mac.
  func adjacent(_ direction: TerminalNavigationDirection, hostIDs: [String]) -> SidebarMacs? {
    guard !hostIDs.isEmpty else { return nil }
    let cycle = [SidebarMacs.thisMac] + hostIDs.map(SidebarMacs.mac) + [.all]
    let current = cycle.firstIndex(of: self) ?? 0
    return SessionNavigation.adjacentIndex(
      from: current, count: cycle.count, direction: direction
    ).map { cycle[$0] }
  }

  /// Whether a Session of `hostID` (nil for this Mac) is listed.
  func includes(hostID: String?) -> Bool {
    switch self {
    case .thisMac: hostID == nil
    case .mac(let shown): hostID == shown
    case .all: true
    }
  }
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

  /// Newest activity first; ties go to the newer Session, then by ID.
  static func sorted(_ sessions: [TerminalSession]) -> [TerminalSession] {
    sessions.sorted { left, right in
      let (leftActivity, rightActivity) = (lastActivity(of: left), lastActivity(of: right))
      if leftActivity != rightActivity { return leftActivity > rightActivity }
      let (leftCreated, rightCreated) = (left.createdAt ?? 0, right.createdAt ?? 0)
      if leftCreated != rightCreated { return leftCreated > rightCreated }
      return left.id.rawValue > right.id.rawValue
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

/// Sessions pinned to the top of the sidebar. Pins belong to this Mac alone: they live in its
/// user defaults and never reach Axod, the cloud or another Mac.
///
/// A pin outlives its Session's absence, because absence is often temporary: another Mac's
/// Session drops out while that Mac is offline, and a closed Session can be reopened (⌘⇧T).
/// A pin whose Session isn't listed does nothing; once there are `capacity` pins the oldest go,
/// so pins of Sessions that are gone for good can't pile up.
struct SessionPins: Equatable {
  static let capacity = 256
  /// Oldest pin first, without duplicates, at most `capacity`.
  private(set) var ids: [SessionID] = []

  init(_ ids: [SessionID] = []) {
    for id in ids where !self.ids.contains(id) { self.ids.append(id) }
    trim()
  }

  /// Pins as stored; entries that aren't Session IDs are dropped.
  init(storedValue: [String]?) {
    self.init((storedValue ?? []).compactMap(SessionID.init(rawValue:)))
  }

  var storedValue: [String] { ids.map(\.rawValue) }

  func contains(_ sessionID: SessionID) -> Bool { ids.contains(sessionID) }

  /// Pins `sessionID`, or unpins it if it is pinned.
  mutating func toggle(_ sessionID: SessionID) {
    if let index = ids.firstIndex(of: sessionID) {
      ids.remove(at: index)
    } else {
      ids.append(sessionID)
      trim()
    }
  }

  /// `sessions` with the pinned ones first. Each group keeps the order it had, so pinned
  /// Sessions still follow recent activity among themselves.
  func pinnedFirst(_ sessions: [TerminalSession]) -> [TerminalSession] {
    guard !ids.isEmpty else { return sessions }
    let pinned = Set(ids)
    return sessions.filter { pinned.contains($0.id) } + sessions.filter { !pinned.contains($0.id) }
  }

  private mutating func trim() {
    if ids.count > Self.capacity { ids.removeFirst(ids.count - Self.capacity) }
  }
}
