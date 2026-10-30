import AxoProtocol
import Foundation

/// A chat in the menu, with the Mac it is on.
public struct ChatMenuEntry: Equatable, Sendable {
  public let host: RemoteHost
  public let session: RemoteSession

  /// A chat's identity in the menu: a session id is only unique on its Mac.
  public struct Key: Hashable, Sendable {
    public let host: UUID
    public let session: SessionID
  }

  public var key: Key { Key(host: host.hostId, session: session.sessionId) }
}

/// One Workspace's chats in the menu.
public struct ChatMenuSection: Identifiable, Equatable, Sendable {
  /// A project, listed by name and folded away by its title; or the Mac's Home Workspace, where
  /// chats go by default, whose chats are listed after the projects without a title of their own.
  public enum Kind: Equatable, Sendable { case project, home }

  public let id: String
  public let title: String
  public let kind: Kind
  public let chats: [ChatMenuEntry]

  public init(id: String, title: String, kind: Kind = .project, chats: [ChatMenuEntry]) {
    self.id = id
    self.title = title
    self.kind = kind
    self.chats = chats
  }

  /// Chats active within this long are listed; older ones wait behind "Show older chats".
  public static let recentWindow: TimeInterval = 8 * 60 * 60

  /// The chats worth listing before older ones are asked for: those active in the last eight
  /// hours, any the agent is working in or needs the person for, and any `keep` names (the open
  /// chat), most recently active first.
  public func recentChats(now: Date, keeping keep: (ChatMenuEntry) -> Bool = { _ in false }) -> [ChatMenuEntry] {
    chats.filter { entry in
      now.timeIntervalSince(ChatMenu.activity(entry.session)) <= Self.recentWindow
        || entry.session.status == .working || entry.session.status == .needsAttention
        || keep(entry)
    }
  }

  /// Whether the agent is busy, or waiting for the person, in any of these chats.
  public var isBusy: Bool { chats.contains { $0.session.status == .working || $0.session.status == .needsAttention } }
}

/// The menu's chats, grouped by Workspace: the projects in alphabetical order, so they stay where
/// they are as chats come and go, then the open Mac's Home Workspace last, its chats under the
/// projects; within each, the most recently active chat first. Bare terminals have no chat in them
/// and are not listed; with several Macs a Workspace's title names its Mac. Only the open Mac's
/// Workspaces are known, so another Mac's Home is listed as a project.
public enum ChatMenu {
  /// `workspaces` are the open Mac's (`openHost`): those with no chat yet are listed too, in their
  /// place, so a new chat's place shows before it exists.
  public static func sections(
    hosts: [RemoteHost], sessionsOf: (RemoteHost) -> [RemoteSession],
    openHost: RemoteHost?, workspaces: [RemoteWorkspace]
  ) -> [ChatMenuSection] {
    func title(_ workspace: String, on host: RemoteHost) -> String {
      hosts.count > 1 ? "\(workspace) · \(host.label)" : workspace
    }
    var grouped: [String: (title: String, chats: [ChatMenuEntry])] = [:]
    for host in hosts {
      for session in sessionsOf(host) where session.hasAgent != false {
        let workspace = session.workspaceName ?? "Chats"
        let key = "\(host.hostId.uuidString)/\(workspace)"
        grouped[key, default: (title(workspace, on: host), [])].chats.append(ChatMenuEntry(host: host, session: session))
      }
    }
    let homeIDs = Set(
      workspaces.filter(\.isHome).compactMap { home in
        openHost.map { "\($0.hostId.uuidString)/\(home.name)" }
      })
    func kind(_ key: String) -> ChatMenuSection.Kind { homeIDs.contains(key) ? .home : .project }
    var sections = grouped.map { key, group in
      ChatMenuSection(id: key, title: group.title, kind: kind(key), chats: group.chats.sorted(by: isMoreRecent))
    }
    if let openHost {
      for workspace in workspaces {
        let key = "\(openHost.hostId.uuidString)/\(workspace.name)"
        if grouped[key] == nil, !sections.contains(where: { $0.id == key }) {
          sections.append(ChatMenuSection(id: key, title: title(workspace.name, on: openHost), kind: kind(key), chats: []))
        }
      }
    }
    return sections.sorted { a, b in
      a.kind != b.kind ? a.kind == .project : isAlphabeticallyBefore(a, b)
    }
  }

  /// By title, as people read them: case and accents aside, numbers by value.
  static func isAlphabeticallyBefore(_ a: ChatMenuSection, _ b: ChatMenuSection) -> Bool {
    switch a.title.localizedStandardCompare(b.title) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: a.id < b.id
    }
  }

  /// Last active first; among chats as recent, the newer one first. Stable as activity is equal.
  static func isMoreRecent(_ a: ChatMenuEntry, than b: ChatMenuEntry) -> Bool {
    let (left, right) = (activity(a.session), activity(b.session))
    if left != right { return left > right }
    if a.session.createdAt != b.session.createdAt {
      return (a.session.createdAt ?? 0) > (b.session.createdAt ?? 0)
    }
    if a.session.sessionId != b.session.sessionId {
      return a.session.sessionId.rawValue > b.session.sessionId.rawValue
    }
    return a.host.hostId.uuidString < b.host.hostId.uuidString
  }

  /// When a chat was last active: its latest completed message, or its creation for a chat with
  /// none yet, as the Mac's recent list orders them. Activity is a finished message, not
  /// streaming, so chats move when a turn produces something rather than on every token. A Mac
  /// too old to report either leaves the snapshot's time, which says when it was sent.
  public static func activity(_ session: RemoteSession) -> Date {
    let seconds = max(session.lastMessageAt ?? 0, session.createdAt ?? 0)
    if seconds > 0 { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
    return (try? Date(session.updatedAt, strategy: .iso8601))
      ?? (try? Date(session.updatedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
      ?? .distantPast
  }

  /// Every chat on every Mac, the most recently active first: the menu's recent list. Bare
  /// terminals have no chat in them and are not listed.
  public static func recent(hosts: [RemoteHost], sessionsOf: (RemoteHost) -> [RemoteSession]) -> [ChatMenuEntry] {
    hosts.flatMap { host in
      sessionsOf(host).filter { $0.hasAgent != false }.map { ChatMenuEntry(host: host, session: $0) }
    }
    .sorted(by: isMoreRecent)
  }

  /// `live` in the order `held` remembers, so rows don't move while the person is looking at the
  /// list. Chats gone drop out; chats new since go first, in `live` order.
  public static func holding(_ held: [ChatMenuEntry.Key]?, live: [ChatMenuEntry]) -> [ChatMenuEntry] {
    guard let held else { return live }
    let byKey = Dictionary(live.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    let heldKeys = Set(held)
    return live.filter { !heldKeys.contains($0.key) } + held.compactMap { byKey[$0] }
  }

  /// A short age for a row, as the Mac's sidebar shows: "now", "5m", "3h", "2d", "4w".
  public static func age(of date: Date, now: Date) -> String {
    let elapsed = max(0, Int(now.timeIntervalSince(date)))
    switch elapsed {
    case ..<60: return "now"
    case ..<3_600: return "\(elapsed / 60)m"
    case ..<86_400: return "\(elapsed / 3_600)h"
    case ..<604_800: return "\(elapsed / 86_400)d"
    default: return "\(elapsed / 604_800)w"
    }
  }
}

/// How the menu lists chats: grouped under their Workspaces, or one list by recent activity.
public enum ChatListMode: String, CaseIterable, Sendable {
  case workspaces
  case recent
}
