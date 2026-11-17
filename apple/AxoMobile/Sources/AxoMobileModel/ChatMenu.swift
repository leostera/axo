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

    public init(host: UUID, session: SessionID) {
      self.host = host
      self.session = session
    }
  }

  public var key: Key { Key(host: host.hostId, session: session.sessionId) }
}

/// Every host's chats, ordered by activity for the Pinned / Active / Earlier list.
public enum ChatMenu {
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
