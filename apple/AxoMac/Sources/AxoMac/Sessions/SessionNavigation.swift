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

/// When this Mac last saw each Session, so the sidebar can tell which have activity nobody has
/// looked at. Like pins, this lives in this Mac's user defaults alone.
///
/// A Session never marked counts as seen at `baseline`, the moment this Mac started keeping
/// track: whatever happened before then isn't news. At most `capacity` marks are kept, dropping
/// the oldest, which then fall back to `baseline` and so read as seen.
struct SessionSeen: Equatable {
  static let capacity = 1024
  /// Unix seconds.
  let baseline: Int64
  private(set) var seenAt: [SessionID: Int64]

  init(baseline: Int64, seenAt: [SessionID: Int64] = [:]) {
    self.baseline = baseline
    self.seenAt = seenAt
    trim()
  }

  /// Marks as stored; entries that aren't Session IDs are dropped.
  init(baseline: Int64, storedValue: [String: Any]?) {
    var marks: [SessionID: Int64] = [:]
    for (key, value) in storedValue ?? [:] {
      guard let id = SessionID(rawValue: key), let seconds = (value as? NSNumber)?.int64Value
      else { continue }
      marks[id] = seconds
    }
    self.init(baseline: baseline, seenAt: marks)
  }

  var storedValue: [String: Int64] {
    Dictionary(uniqueKeysWithValues: seenAt.map { ($0.key.rawValue, $0.value) })
  }

  /// Whether `session` has had activity since it was last seen.
  func isUnseen(_ session: TerminalSession) -> Bool {
    SessionActivityOrder.lastActivity(of: session) > (seenAt[session.id] ?? baseline)
  }

  /// Marks `session` seen at `now`, or at its last activity if that is later (another Mac's
  /// clock may run ahead). Returns whether anything changed.
  @discardableResult
  mutating func markSeen(_ session: TerminalSession, now: Int64) -> Bool {
    let mark = max(now, SessionActivityOrder.lastActivity(of: session))
    guard isUnseen(session) || seenAt[session.id] == nil else { return false }
    guard (seenAt[session.id] ?? .min) < mark else { return false }
    seenAt[session.id] = mark
    trim()
    return true
  }

  private mutating func trim() {
    guard seenAt.count > Self.capacity else { return }
    for (id, _) in seenAt.sorted(by: { $0.value < $1.value }).prefix(seenAt.count - Self.capacity) {
      seenAt[id] = nil
    }
  }
}

/// The sidebar's groups, top to bottom.
enum SidebarGroup: Int, CaseIterable, Comparable {
  /// Pinned Sessions, in the order they were pinned.
  case pinned
  /// Sessions working or waiting on you, active in the last few minutes, or with activity not
  /// yet seen; A to Z, so they hold still however busy they are.
  case active
  /// Everything else, latest activity first. These are quiet, so they rarely move.
  case earlier

  static func < (left: SidebarGroup, right: SidebarGroup) -> Bool { left.rawValue < right.rawValue }

  var title: String {
    switch self {
    case .pinned: "Pinned"
    case .active: "Active"
    case .earlier: "Earlier"
    }
  }
}

struct SidebarSection: Equatable, Identifiable {
  let group: SidebarGroup
  let sessions: [TerminalSession]
  var id: SidebarGroup { group }
}

/// How rows are ordered within one of the sidebar's groups.
enum SidebarRowOrder: String, Codable, CaseIterable, Identifiable {
  /// The order they were pinned in; only for Pinned.
  case pinned
  /// A to Z by name: holds still however busy the Sessions are.
  case name
  /// Newest Session first: holds still too, as creation never changes.
  case created
  /// Latest activity first: moves whenever another Session gets busier.
  case activity

  var id: String { rawValue }

  var title: String {
    switch self {
    case .pinned: "Order pinned"
    case .name: "Name (A to Z)"
    case .created: "Newest first"
    case .activity: "Latest activity"
    }
  }

  static let forPinned: [SidebarRowOrder] = [.pinned, .name, .activity]
  static let forGroups: [SidebarRowOrder] = [.name, .created, .activity]
}

/// How unseen activity shows in a sidebar row.
enum UnseenMarker: String, Codable, CaseIterable, Identifiable {
  case dotAndBold
  case dot
  case bold
  case none

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dotAndBold: "Dot and bold name"
    case .dot: "Dot"
    case .bold: "Bold name"
    case .none: "Nothing"
    }
  }

  var showsDot: Bool { self == .dotAndBold || self == .dot }
  var showsBold: Bool { self == .dotAndBold || self == .bold }
}

/// The sidebar's grouping, as set in Settings → Sessions, saved on this Mac.
struct SidebarGroupingSettings: Codable, Equatable {
  static let activeWindowChoices = [1, 3, 5, 10, 15, 30, 60]
  static let regroupIntervalChoices = [10, 30, 60, 300]

  /// How long a Session stays Active after its last activity.
  var activeWindowMinutes = 3
  /// How often Sessions are moved between groups, in seconds.
  var regroupIntervalSeconds = 30
  /// Whether a Session with activity this Mac hasn't seen stays Active until it is seen.
  var unseenStayActive = true
  var unseenMarker = UnseenMarker.dotAndBold
  var pinnedOrder = SidebarRowOrder.pinned
  var activeOrder = SidebarRowOrder.name
  var earlierOrder = SidebarRowOrder.activity
  var showsGroupTitles = true

  init() {}

  /// Settings as stored; anything missing or out of range takes its default, so a newer or
  /// older Axo's settings never fail to load.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self()
    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
      ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
    activeWindowMinutes = min(max(value(.activeWindowMinutes, defaults.activeWindowMinutes), 1), 24 * 60)
    regroupIntervalSeconds = min(max(value(.regroupIntervalSeconds, defaults.regroupIntervalSeconds), 5), 3_600)
    unseenStayActive = value(.unseenStayActive, defaults.unseenStayActive)
    unseenMarker = value(.unseenMarker, defaults.unseenMarker)
    pinnedOrder = value(.pinnedOrder, defaults.pinnedOrder)
    activeOrder = value(.activeOrder, defaults.activeOrder)
    earlierOrder = value(.earlierOrder, defaults.earlierOrder)
    showsGroupTitles = value(.showsGroupTitles, defaults.showsGroupTitles)
  }

  init(storedValue: Data?) {
    self = storedValue.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
  }

  var storedValue: Data? { try? JSONEncoder().encode(self) }

  var activeWindow: Int64 { Int64(activeWindowMinutes) * 60 }
}

/// Sorts the sidebar into groups by what needs you rather than by the minute, so a row moves
/// only when its Session joins or leaves a group, never because another one got busier.
enum SessionGrouping {
  static func group(
    of session: TerminalSession, pins: SessionPins, seen: SessionSeen, now: Int64,
    settings: SidebarGroupingSettings = .init()
  ) -> SidebarGroup {
    if pins.contains(session.id) { return .pinned }
    if session.status == .working || session.status == .needsAttention { return .active }
    if settings.unseenStayActive && seen.isUnseen(session) { return .active }
    if now - SessionActivityOrder.lastActivity(of: session) < settings.activeWindow { return .active }
    return .earlier
  }

  /// `sessions` in their groups; groups without Sessions are left out.
  static func sections(
    _ sessions: [TerminalSession], pins: SessionPins, seen: SessionSeen, now: Int64,
    settings: SidebarGroupingSettings = .init()
  ) -> [SidebarSection] {
    let byGroup = Dictionary(grouping: sessions) {
      group(of: $0, pins: pins, seen: seen, now: now, settings: settings)
    }
    return SidebarGroup.allCases.compactMap { group in
      guard let members = byGroup[group], !members.isEmpty else { return nil }
      let rowOrder: SidebarRowOrder =
        switch group {
        case .pinned: settings.pinnedOrder
        case .active: settings.activeOrder
        case .earlier: settings.earlierOrder
        }
      return SidebarSection(group: group, sessions: order(members, by: rowOrder, pins: pins))
    }
  }

  /// `live` shown as `held` remembers it, so rows don't move under the pointer: each held
  /// Session keeps its group and place, Sessions new since go first in their live group, and
  /// closed ones drop out. Pins apply at once, so a Session pinned under the pointer moves up.
  static func holding(
    _ held: [SidebarSection]?, live: [SidebarSection], pins: SessionPins
  ) -> [SidebarSection] {
    guard let held else { return live }
    let liveByID = Dictionary(
      live.flatMap { section in section.sessions.map { ($0.id, ($0, section.group)) } },
      uniquingKeysWith: { first, _ in first })
    var heldGroup: [SessionID: SidebarGroup] = [:]
    for section in held { for session in section.sessions { heldGroup[session.id] = section.group } }

    func placement(_ id: SessionID) -> SidebarGroup? {
      guard let (_, liveGroup) = liveByID[id] else { return nil }
      if liveGroup == .pinned { return .pinned }
      guard let group = heldGroup[id], group != .pinned else { return liveGroup }
      return group
    }

    return SidebarGroup.allCases.compactMap { group in
      let members: [TerminalSession]
      if group == .pinned {
        members = live.first { $0.group == .pinned }?.sessions ?? []
      } else {
        let fresh = live.first { $0.group == group }?.sessions.filter {
          heldGroup[$0.id] == nil || heldGroup[$0.id] == .pinned
        } ?? []
        let kept = held.first { $0.group == group }?.sessions.compactMap { session in
          placement(session.id) == group ? liveByID[session.id]?.0 : nil
        } ?? []
        members = fresh + kept
      }
      return members.isEmpty ? nil : SidebarSection(group: group, sessions: members)
    }
  }

  private static func order(
    _ sessions: [TerminalSession], by rowOrder: SidebarRowOrder, pins: SessionPins
  ) -> [TerminalSession] {
    switch rowOrder {
    case .pinned:
      let rank = Dictionary(uniqueKeysWithValues: pins.ids.enumerated().map { ($1, $0) })
      return sessions.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    case .name:
      return sessions.sorted { left, right in
        switch left.displayName.localizedStandardCompare(right.displayName) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: left.id.rawValue < right.id.rawValue
        }
      }
    case .created:
      return sessions.sorted { left, right in
        let (leftCreated, rightCreated) = (left.createdAt ?? 0, right.createdAt ?? 0)
        if leftCreated != rightCreated { return leftCreated > rightCreated }
        return left.id.rawValue > right.id.rawValue
      }
    case .activity:
      return SessionActivityOrder.sorted(sessions)
    }
  }
}
