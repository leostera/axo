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
}

/// The menu's chats, grouped by Workspace, the most recently active first: the chats within a
/// Workspace by their last activity, and the Workspaces by their most recent chat. Bare
/// terminals have no chat in them and are not listed; with several Macs a Workspace's title
/// names its Mac.
public enum ChatMenu {
  /// `workspaces` are the open Mac's (`openHost`): those with no chat yet are listed last, so a
  /// new chat's place shows before it exists.
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
    sections.sort { isMoreRecent($0.chats[0], than: $1.chats[0]) }
    if let openHost {
      for workspace in workspaces {
        let key = "\(openHost.hostId.uuidString)/\(workspace.name)"
        if grouped[key] == nil, !sections.contains(where: { $0.id == key }) {
          sections.append(ChatMenuSection(id: key, title: title(workspace.name, on: openHost), chats: []))
        }
      }
    }
    return sections
  }

  /// Last active first; among chats as recent, the newer one first. Stable as activity is equal.
  static func isMoreRecent(_ a: ChatMenuEntry, than b: ChatMenuEntry) -> Bool {
    let (left, right) = (activity(a.session), activity(b.session))
    if left != right { return left > right }
    if a.session.sessionId != b.session.sessionId { return a.session.sessionId > b.session.sessionId }
    return a.host.hostId.uuidString < b.host.hostId.uuidString
  }

  private static func activity(_ session: RemoteSession) -> Date {
    (try? Date(session.updatedAt, strategy: .iso8601))
      ?? (try? Date(session.updatedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
      ?? .distantPast
  }
}
