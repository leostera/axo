import AxoProtocol
import AxoSearch

/// Fuzzy title/folder matches first, then activity; empty searches show the most recent chats.
public enum ChatSearch {
  public static func matches(
    _ query: String, hosts: [RemoteHost], sessionsOf: (RemoteHost) -> [RemoteSession]
  ) -> [ChatMenuEntry] {
    let entries = ChatMenu.recent(hosts: hosts, sessionsOf: sessionsOf)
    return SearchIndex(entries) {
      SearchDocument(title: $0.session.displayName, subtitle: $0.session.folderName ?? "")
    }.search(SearchQuery(query))
      .sorted {
        if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
        return ChatMenu.isMoreRecent($0.item, than: $1.item)
      }
      .map(\.item)
  }
}
