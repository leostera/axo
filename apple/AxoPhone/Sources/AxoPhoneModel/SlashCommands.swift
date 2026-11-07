import AxoProtocol
import Foundation

/// The `/` list over the message box (RFD0033): the chat's Pi's own commands, narrowed by what
/// follows the `/` at the start of the box. It goes once arguments start.
public enum SlashCommands {
  /// What follows a `/` that starts the box, while the command's name is still being typed; nil
  /// when the box doesn't start with one, or the name is done.
  public static func query(in draft: String) -> String? {
    guard draft.first == "/" else { return nil }
    let name = draft.dropFirst()
    guard !name.contains(where: \.isWhitespace) else { return nil }
    return String(name)
  }

  /// The commands whose name has `query` in it: those starting with it first, then by name.
  public static func matching(_ commands: [PiCommand], query: String) -> [PiCommand] {
    let query = query.lowercased()
    func rank(_ command: PiCommand) -> Int? {
      let name = command.name.lowercased()
      if query.isEmpty || name.hasPrefix(query) { return 0 }
      return name.contains(query) ? 1 : nil
    }
    let ranked: [(command: PiCommand, rank: Int)] = commands.compactMap { command in
      rank(command).map { (command, $0) }
    }
    let sorted = ranked.sorted { a, b in
      if a.rank != b.rank { return a.rank < b.rank }
      return a.command.name.localizedStandardCompare(b.command.name) == .orderedAscending
    }
    return sorted.map(\.command)
  }

  /// What choosing `command` puts in the box: its name, ready for arguments.
  public static func inserting(_ command: PiCommand) -> String { "/\(command.name) " }
}
