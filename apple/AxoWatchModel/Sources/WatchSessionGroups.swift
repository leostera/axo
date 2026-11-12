import AxoPhoneModel
import AxoProtocol
import Foundation

/// One account-wide list, never one section per machine. Empty pins deliberately produce only
/// Active and Earlier; classification and ordering are the iPhone/web's shared rules.
public enum WatchSessionGroups {
  public static func sections(
    hosts: [RemoteHost], sessionsOf: (RemoteHost) -> [RemoteSession], seen: ChatSeen,
    now: Date = .now, settings: ChatGroupingSettings = .init()
  ) -> [ChatGroupSection] {
    ChatGrouping.sections(
      ChatMenu.recent(hosts: hosts, sessionsOf: sessionsOf),
      pins: ChatPins(), seen: seen, now: Int64(now.timeIntervalSince1970), settings: settings)
  }
}
