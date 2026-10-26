import AxoProtocol
import AxoSearch
import Foundation

/// What choosing a palette entry does.
enum CommandPaletteAction: Hashable {
  case showSession(SessionID)
  case focusPane(ShellID)
  case cloneGitHubRepository(GitHubRepository)
  case run(CommandPaletteCommand)
}

/// The app commands the palette offers, each also reachable from a menu.
///
/// Destructive commands name what the palette showed them acting on, so they never act on
/// something else if the catalog changed while the palette was open.
enum CommandPaletteCommand: Hashable {
  case newSession
  case newSessionInWorkspace(workspaceID: String)
  case newWorkspace
  case splitRight
  case splitDown
  case closeShell(ShellID)
  case closeSession(SessionID)
  case toggleSidebar
  case openSettings
}

/// One palette entry.
struct CommandPaletteItem: Identifiable, Equatable {
  enum Kind: Equatable {
    case session
    case pane
    case command
  }

  /// Stable across rebuilds, so the selection can follow an entry.
  let id: String
  let kind: Kind
  let title: String
  let subtitle: String
  /// Hidden words that also find the entry.
  let keywords: [String]
  /// The menu shortcut, as shown in menus (⌘T).
  let shortcut: String?
  /// The Session that is already shown.
  let isCurrent: Bool
  let action: CommandPaletteAction

  var document: SearchDocument {
    SearchDocument(title: title, subtitle: subtitle, keywords: keywords)
  }
}

/// What the palette is built from: a snapshot of the catalog and the current selection.
struct CommandPaletteContext {
  /// Every open Session, in sidebar order.
  var sessions: [TerminalSession]
  var workspaces: [WorkspaceRecord]
  /// Most recently shown first.
  var recentSessionIDs: [SessionID]
  var selectedSessionID: SessionID?
  var focusedShellID: ShellID?
  var availability: TerminalCommandAvailability
  /// Abbreviated to `~` in directories.
  var homeDirectory: String
}

/// Builds the palette's entries. With an empty query they are shown in this order: Sessions
/// most recently shown first (the current one last, as switching away is the common case),
/// then panes of multi-pane Sessions, then the commands that can run now.
enum CommandPaletteCatalog {
  static func items(_ context: CommandPaletteContext) -> [CommandPaletteItem] {
    sessionItems(context) + paneItems(context) + commandItems(context)
  }

  private static func sessionItems(_ context: CommandPaletteContext) -> [CommandPaletteItem] {
    let byID = Dictionary(uniqueKeysWithValues: context.sessions.map { ($0.id, $0) })
    var ordered: [TerminalSession] = []
    var seen = Set<SessionID>()
    for id in context.recentSessionIDs where id != context.selectedSessionID {
      if let session = byID[id], seen.insert(id).inserted { ordered.append(session) }
    }
    for session in context.sessions where session.id != context.selectedSessionID {
      if seen.insert(session.id).inserted { ordered.append(session) }
    }
    if let selected = context.selectedSessionID.flatMap({ byID[$0] }) { ordered.append(selected) }

    return ordered.map { session in
      let status = session.status.flatMap(statusDescription)
      let lastMessage = session.lastMessageAt.map(relativeLastMessageDescription)
      return CommandPaletteItem(
        id: "session:\(session.id.rawValue)",
        kind: .session,
        title: [session.emoji, session.displayName].compactMap { $0 }.joined(separator: " "),
        subtitle: [session.workspaceName, lastMessage, status, abbreviated(session.initialPwd, context)]
          .compactMap { $0 }.joined(separator: " · "),
        keywords: ["session"],
        shortcut: nil,
        isCurrent: session.id == context.selectedSessionID,
        action: .showSession(session.id))
    }
  }

  private static func paneItems(_ context: CommandPaletteContext) -> [CommandPaletteItem] {
    context.sessions.filter { $0.shells.count >= 2 }.flatMap { session in
      var shellNumber = 0
      return session.shells.map { shell in
        let name: String
        switch shell.role {
        case .pi:
          name = "Pi"
        case .terminal:
          shellNumber += 1
          name = "Shell \(shellNumber)"
        }
        return CommandPaletteItem(
          id: "pane:\(shell.id.rawValue)",
          kind: .pane,
          title: "\(name) — \(session.displayName)",
          subtitle: abbreviated(shell.initialPwd, context),
          keywords: ["pane", shell.isPi ? "agent" : "terminal"]
            + [session.workspaceName].compactMap { $0 },
          shortcut: nil,
          isCurrent: false,
          action: .focusPane(shell.id))
      }
    }
  }

  private static func commandItems(_ context: CommandPaletteContext) -> [CommandPaletteItem] {
    let availability = context.availability
    let selected = context.selectedSessionID.flatMap { id in
      context.sessions.first { $0.id == id }
    }
    var commands: [CommandPaletteItem] = []
    func add(
      _ command: CommandPaletteCommand, _ title: String, subtitle: String = "",
      keywords: [String] = [], shortcut: String? = nil, id: String? = nil
    ) {
      commands.append(
        CommandPaletteItem(
          id: "command:\(id ?? title)", kind: .command, title: title, subtitle: subtitle,
          keywords: keywords + ["command"], shortcut: shortcut, isCurrent: false,
          action: .run(command)))
    }

    add(
      .newSession, "New Session", subtitle: selected?.workspaceName ?? "",
      keywords: ["create", "tab"], shortcut: "⌘T")
    for workspace in context.workspaces {
      add(
        .newSessionInWorkspace(workspaceID: workspace.workspaceId),
        "New Session in \(workspace.name)",
        subtitle: abbreviated(workspace.directoryPath, context),
        keywords: ["create", "workspace"], id: "new-session-in:\(workspace.workspaceId)")
    }
    add(.newWorkspace, "New Workspace…", keywords: ["create", "folder"], shortcut: "⌘N")
    if availability.hasFocusedShell {
      add(.splitRight, "Split Right", keywords: ["pane", "vertical"], shortcut: "⌘D")
      add(.splitDown, "Split Down", keywords: ["pane", "horizontal"], shortcut: "⇧⌘D")
      if let focused = context.focusedShellID {
        add(.closeShell(focused), "Close Focused Shell", keywords: ["pane"], shortcut: "⌘W")
      }
    }
    if availability.hasSelectedSession, let selected {
      add(.closeSession(selected.id), "Close Session", subtitle: selected.displayName)
    }
    add(.toggleSidebar, "Toggle Sidebar", shortcut: "⌃⌘S")
    add(.openSettings, "Settings…", keywords: ["preferences"], shortcut: "⌘,")
    return commands
  }

  private static func relativeLastMessageDescription(_ timestamp: Int64) -> String {
    let elapsed = max(0, Int64(Date().timeIntervalSince1970) - timestamp)
    guard elapsed >= 60 else { return "just now" }

    let (count, unit) = if elapsed < 60 * 60 {
      (elapsed / 60, "minute")
    } else if elapsed < 24 * 60 * 60 {
      (elapsed / (60 * 60), "hour")
    } else {
      (elapsed / (24 * 60 * 60), "day")
    }
    let plural = count == 1 ? "" : "s"
    return "\(count) \(unit)\(plural) ago"
  }

  /// Only states worth reading in a list; `ready` is the default and says nothing.
  private static func statusDescription(_ status: TerminalSessionStatus) -> String? {
    switch status {
    case .ready: nil
    case .starting: "Starting"
    case .working: "Working"
    case .needsAttention: "Needs attention"
    case .unavailable: "Unavailable"
    }
  }

  static func abbreviated(_ path: String, _ context: CommandPaletteContext) -> String {
    let home = context.homeDirectory
    guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }
}
