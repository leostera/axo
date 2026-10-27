import AxoProtocol
import Foundation

/// A chat in the menu, with the Mac it is on.
public struct ChatMenuEntry: Equatable, Sendable {
  public let host: RemoteHost
  public let session: RemoteSession
}

/// One Workspace's chats in the menu.
public struct ChatMenuSection: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let chats: [ChatMenuEntry]

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

/// The menu's chats, grouped by Workspace: the open Mac's Home Workspace first, then the rest in
/// alphabetical order, so they stay where they are as chats come and go, and the chats within each the most recently active first.
/// Bare terminals have no chat in them and are not listed; with several Macs a Workspace's title
/// names its Mac.
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
    var sections = grouped.map { key, group in
      ChatMenuSection(id: key, title: group.title, chats: group.chats.sorted(by: isMoreRecent))
    }
    if let openHost {
      for workspace in workspaces {
        let key = "\(openHost.hostId.uuidString)/\(workspace.name)"
        if grouped[key] == nil, !sections.contains(where: { $0.id == key }) {
          sections.append(ChatMenuSection(id: key, title: title(workspace.name, on: openHost), chats: []))
        }
      }
    }
    let homeIDs = Set(
      workspaces.filter(\.isHome).compactMap { home in
        openHost.map { "\($0.hostId.uuidString)/\(home.name)" }
      })
    return sections.sorted { a, b in
      let (aIsHome, bIsHome) = (homeIDs.contains(a.id), homeIDs.contains(b.id))
      return aIsHome != bIsHome ? aIsHome : isAlphabeticallyBefore(a, b)
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
    if a.session.sessionId != b.session.sessionId { return a.session.sessionId > b.session.sessionId }
    return a.host.hostId.uuidString < b.host.hostId.uuidString
  }

  static func activity(_ session: RemoteSession) -> Date {
    (try? Date(session.updatedAt, strategy: .iso8601))
      ?? (try? Date(session.updatedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
      ?? .distantPast
  }
}
