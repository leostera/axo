import AxoProtocol
import Foundation
import Observation

/// The chat list's groups, as the Mac's sidebar has them (SessionNavigation.swift) and the web app
/// lists them: Pinned, then Active, then Earlier. Pins, what was seen and how to group live on this
/// phone alone, under the Mac's key names, and never reach the Mac, the cloud or another device.
public enum ChatGroup: Int, CaseIterable, Comparable, Sendable {
  /// Pinned chats, in the order they were pinned.
  case pinned
  /// Chats working or waiting on the person, active in the last few minutes, or with activity
  /// not yet seen.
  case active
  /// Everything else.
  case earlier

  public static func < (left: ChatGroup, right: ChatGroup) -> Bool { left.rawValue < right.rawValue }

  public var title: String {
    switch self {
    case .pinned: "Pinned"
    case .active: "Active"
    case .earlier: "Earlier"
    }
  }
}

public struct ChatGroupSection: Identifiable, Equatable, Sendable {
  public let group: ChatGroup
  public let chats: [ChatMenuEntry]
  public var id: ChatGroup { group }
}

// MARK: - Pins

/// Chats pinned to the top of the list, by Session id. A pin outlives its chat's absence, because
/// absence is often temporary (a Mac offline, a chat reopened); a pin whose chat is not listed does
/// nothing, and once there are `capacity` pins the oldest go.
public struct ChatPins: Equatable, Sendable {
  public static let capacity = 256
  /// Oldest pin first, without duplicates, at most `capacity`.
  public private(set) var ids: [SessionID] = []

  public init(_ ids: [SessionID] = []) {
    for id in ids where !self.ids.contains(id) { self.ids.append(id) }
    trim()
  }

  /// Pins as stored; entries that are not Session ids are dropped.
  public init(storedValue: [String]?) {
    self.init((storedValue ?? []).compactMap(SessionID.init(rawValue:)))
  }

  public var storedValue: [String] { ids.map(\.rawValue) }

  public func contains(_ id: SessionID) -> Bool { ids.contains(id) }

  /// Pins `id`, or unpins it if it is pinned.
  public mutating func toggle(_ id: SessionID) {
    if let index = ids.firstIndex(of: id) {
      ids.remove(at: index)
    } else {
      ids.append(id)
      trim()
    }
  }

  private mutating func trim() {
    if ids.count > Self.capacity { ids.removeFirst(ids.count - Self.capacity) }
  }
}

// MARK: - Seen

/// When this phone last saw each chat, so the list can tell which have activity nobody looked at.
/// A chat never marked counts as seen at `baseline`, when this phone started keeping track.
public struct ChatSeen: Equatable, Sendable {
  public static let capacity = 1024
  /// Unix seconds.
  public let baseline: Int64
  public private(set) var seenAt: [SessionID: Int64]

  public init(baseline: Int64, seenAt: [SessionID: Int64] = [:]) {
    self.baseline = baseline
    self.seenAt = seenAt
    trim()
  }

  public init(baseline: Int64, storedValue: [String: Any]?) {
    var marks: [SessionID: Int64] = [:]
    for (key, value) in storedValue ?? [:] {
      guard let id = SessionID(rawValue: key), let seconds = (value as? NSNumber)?.int64Value else { continue }
      marks[id] = seconds
    }
    self.init(baseline: baseline, seenAt: marks)
  }

  public var storedValue: [String: Int64] {
    Dictionary(uniqueKeysWithValues: seenAt.map { ($0.key.rawValue, $0.value) })
  }

  public func isUnseen(_ session: RemoteSession) -> Bool {
    ChatGrouping.lastActivity(of: session) > (seenAt[session.sessionId] ?? baseline)
  }

  /// Marks `session` seen at `now`, or at its last activity if later (a Mac's clock may run
  /// ahead). Returns whether anything changed.
  @discardableResult
  public mutating func markSeen(_ session: RemoteSession, now: Int64) -> Bool {
    let mark = max(now, ChatGrouping.lastActivity(of: session))
    guard isUnseen(session) || seenAt[session.sessionId] == nil else { return false }
    guard (seenAt[session.sessionId] ?? .min) < mark else { return false }
    seenAt[session.sessionId] = mark
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

// MARK: - Settings

/// How rows are ordered within a group.
public enum ChatRowOrder: String, Codable, CaseIterable, Identifiable, Sendable {
  case pinned, name, created, activity
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .pinned: "Order pinned"
    case .name: "Name (A to Z)"
    case .created: "Newest first"
    case .activity: "Latest activity"
    }
  }
  public static let forPinned: [ChatRowOrder] = [.pinned, .name, .activity]
  public static let forGroups: [ChatRowOrder] = [.name, .created, .activity]
}

/// How unseen activity shows in a row.
public enum ChatUnseenMarker: String, Codable, CaseIterable, Identifiable, Sendable {
  case dotAndBold, dot, bold, none
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .dotAndBold: "Dot and bold name"
    case .dot: "Dot"
    case .bold: "Bold name"
    case .none: "Nothing"
    }
  }
  public var showsDot: Bool { self == .dotAndBold || self == .dot }
  public var showsBold: Bool { self == .dotAndBold || self == .bold }
}

/// How the list groups chats, from Settings › Chats, saved on this phone. The defaults are the
/// Mac's; Earlier starts open with every chat, as the Mac lists it.
public struct ChatGroupingSettings: Codable, Equatable, Sendable {
  public static let activeWindowChoices = [1, 3, 5, 10, 15, 30, 60]
  public static let regroupIntervalChoices = [10, 30, 60, 300]
  /// How many Earlier chats show before "Show all"; nil is every one.
  public static let earlierLimitChoices: [Int?] = [nil, 5, 10, 20, 50]

  public var activeWindowMinutes = 3
  public var regroupIntervalSeconds = 30
  public var unseenStayActive = true
  public var unseenMarker = ChatUnseenMarker.dotAndBold
  public var pinnedOrder = ChatRowOrder.pinned
  public var activeOrder = ChatRowOrder.name
  public var earlierOrder = ChatRowOrder.activity
  public var showsGroupTitles = true
  /// Whether Earlier starts folded away under its title.
  public var earlierCollapsed = false
  /// How many Earlier chats show before "Show all"; nil shows every one.
  public var earlierLimit: Int?

  public init() {}

  /// Settings as stored; anything missing or out of range takes its default, so a newer or older
  /// Axo's settings always load.
  public init(from decoder: Decoder) throws {
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
    let active = value(.activeOrder, defaults.activeOrder)
    activeOrder = Self.groupOrderOrDefault(active, defaults.activeOrder)
    earlierOrder = Self.groupOrderOrDefault(value(.earlierOrder, defaults.earlierOrder), defaults.earlierOrder)
    showsGroupTitles = value(.showsGroupTitles, defaults.showsGroupTitles)
    earlierCollapsed = value(.earlierCollapsed, defaults.earlierCollapsed)
    let limit: Int? = value(.earlierLimit, nil)
    earlierLimit = limit.flatMap { $0 > 0 ? min($0, 1_000) : nil }
  }

  private static func groupOrderOrDefault(_ order: ChatRowOrder, _ fallback: ChatRowOrder) -> ChatRowOrder {
    ChatRowOrder.forGroups.contains(order) ? order : fallback
  }

  public init(storedValue: Data?) {
    self = storedValue.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
  }

  public var storedValue: Data? { try? JSONEncoder().encode(self) }

  public var activeWindow: Int64 { Int64(activeWindowMinutes) * 60 }
}

// MARK: - Grouping

public enum ChatGrouping {
  /// When a chat was last active, in Unix seconds, as `ChatMenu.activity` reads it.
  public static func lastActivity(of session: RemoteSession) -> Int64 {
    Int64(ChatMenu.activity(session).timeIntervalSince1970)
  }

  /// The group a chat belongs in: Pinned if pinned; Active while its agent works or waits for the
  /// person, while it has activity not yet seen (if so set), or for a while after its last
  /// activity; otherwise Earlier.
  public static func group(
    of entry: ChatMenuEntry, pins: ChatPins, seen: ChatSeen, now: Int64,
    settings: ChatGroupingSettings = .init(), asking: Set<SessionID> = []
  ) -> ChatGroup {
    let session = entry.session
    if pins.contains(session.sessionId) { return .pinned }
    if session.status == .working || session.status == .needsAttention || asking.contains(session.sessionId) {
      return .active
    }
    if settings.unseenStayActive && seen.isUnseen(session) { return .active }
    if now - lastActivity(of: session) < settings.activeWindow { return .active }
    return .earlier
  }

  /// The chats in their groups, top to bottom; a group without chats is left out.
  public static func sections(
    _ entries: [ChatMenuEntry], pins: ChatPins, seen: ChatSeen, now: Int64,
    settings: ChatGroupingSettings = .init(), asking: Set<SessionID> = []
  ) -> [ChatGroupSection] {
    let byGroup = Dictionary(grouping: entries) {
      group(of: $0, pins: pins, seen: seen, now: now, settings: settings, asking: asking)
    }
    return ChatGroup.allCases.compactMap { group in
      guard let members = byGroup[group], !members.isEmpty else { return nil }
      let order: ChatRowOrder =
        switch group {
        case .pinned: settings.pinnedOrder
        case .active: settings.activeOrder
        case .earlier: settings.earlierOrder
        }
      return ChatGroupSection(group: group, chats: ordered(members, by: order, pins: pins))
    }
  }

  /// `live` shown as `held` remembers it, so rows don't move while the person looks at the list:
  /// each held chat keeps its group and place, chats new since go first in their live group, and
  /// gone ones drop out. Pins apply at once.
  public static func holding(_ held: [ChatGroupSection]?, live: [ChatGroupSection]) -> [ChatGroupSection] {
    guard let held else { return live }
    var liveByKey: [ChatMenuEntry.Key: (ChatMenuEntry, ChatGroup)] = [:]
    for section in live { for entry in section.chats { liveByKey[entry.key] = (entry, section.group) } }
    var heldGroup: [ChatMenuEntry.Key: ChatGroup] = [:]
    for section in held { for entry in section.chats { heldGroup[entry.key] = section.group } }
    func placement(_ key: ChatMenuEntry.Key) -> ChatGroup? {
      guard let (_, liveGroup) = liveByKey[key] else { return nil }
      if liveGroup == .pinned { return .pinned }
      guard let group = heldGroup[key], group != .pinned else { return liveGroup }
      return group
    }
    return ChatGroup.allCases.compactMap { group in
      let members: [ChatMenuEntry]
      if group == .pinned {
        members = live.first { $0.group == .pinned }?.chats ?? []
      } else {
        let fresh = live.first { $0.group == group }?.chats.filter {
          heldGroup[$0.key] == nil || heldGroup[$0.key] == .pinned
        } ?? []
        let kept = held.first { $0.group == group }?.chats.compactMap { entry in
          placement(entry.key) == group ? liveByKey[entry.key]?.0 : nil
        } ?? []
        members = fresh + kept
      }
      return members.isEmpty ? nil : ChatGroupSection(group: group, chats: members)
    }
  }

  static func ordered(_ entries: [ChatMenuEntry], by order: ChatRowOrder, pins: ChatPins) -> [ChatMenuEntry] {
    switch order {
    case .pinned:
      let rank = Dictionary(uniqueKeysWithValues: pins.ids.enumerated().map { ($1, $0) })
      return entries.sorted { (rank[$0.session.sessionId] ?? .max) < (rank[$1.session.sessionId] ?? .max) }
    case .name:
      return entries.sorted { left, right in
        switch left.session.displayName.localizedStandardCompare(right.session.displayName) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: left.session.sessionId.rawValue < right.session.sessionId.rawValue
        }
      }
    case .created:
      return entries.sorted { left, right in
        let (leftCreated, rightCreated) = (left.session.createdAt ?? 0, right.session.createdAt ?? 0)
        if leftCreated != rightCreated { return leftCreated > rightCreated }
        return left.session.sessionId.rawValue > right.session.sessionId.rawValue
      }
    case .activity:
      return entries.sorted(by: ChatMenu.isMoreRecent)
    }
  }
}

// MARK: - Preferences

/// This phone's pins, seen marks and grouping settings, saved in its user defaults as they change.
@MainActor
@Observable
public final class ChatListPreferences {
  public enum Key {
    public static let pins = "sidebar.pinnedSessions.v1"
    public static let seen = "sidebar.seenSessions.v1"
    public static let seenBaseline = "sidebar.seenSessionsBaseline.v1"
    public static let grouping = "sidebar.grouping.v1"
  }

  public private(set) var pins: ChatPins
  public private(set) var seen: ChatSeen
  public var settings: ChatGroupingSettings {
    didSet { defaults.set(settings.storedValue, forKey: Key.grouping) }
  }
  @ObservationIgnored private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard, now: Date = .now) {
    self.defaults = defaults
    pins = ChatPins(storedValue: defaults.stringArray(forKey: Key.pins))
    let baseline: Int64
    if let stored = defaults.object(forKey: Key.seenBaseline) as? NSNumber {
      baseline = stored.int64Value
    } else {
      baseline = Int64(now.timeIntervalSince1970)
      defaults.set(baseline, forKey: Key.seenBaseline)
    }
    seen = ChatSeen(baseline: baseline, storedValue: defaults.dictionary(forKey: Key.seen))
    settings = ChatGroupingSettings(storedValue: defaults.data(forKey: Key.grouping))
  }

  public func togglePin(_ id: SessionID) {
    pins.toggle(id)
    defaults.set(pins.storedValue, forKey: Key.pins)
  }

  public func markSeen(_ session: RemoteSession, now: Date = .now) {
    guard seen.markSeen(session, now: Int64(now.timeIntervalSince1970)) else { return }
    defaults.set(seen.storedValue, forKey: Key.seen)
  }
}
