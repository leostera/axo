import AxoProtocol
import Foundation

/// Performs a chosen palette action against the catalog as it is now, not as it was when the
/// palette opened: anything that has closed or changed since is skipped (and traced) rather
/// than guessed at.
@MainActor
struct CommandPalettePerformer {
  let sessions: TerminalSessionsModel
  let toggleSidebar: () -> Void
  let newWorkspace: () -> Void
  let cloneGitHubRepository: (GitHubRepository) -> Void
  let openSettings: () -> Void

  /// Whether the action was started; `false` means its target is gone.
  @discardableResult
  func perform(_ action: CommandPaletteAction) -> Bool {
    switch action {
    case .showSession(let sessionID):
      guard sessions.session(for: sessionID) != nil else { return skipped(action) }
      sessions.showSession(sessionID)
    case .focusPane(let shellID):
      guard sessions.shell(for: shellID) != nil else { return skipped(action) }
      sessions.focus(shellID)
    case .cloneGitHubRepository(let repository):
      cloneGitHubRepository(repository)
    case .run(let command):
      return run(command)
    }
    return true
  }

  private func run(_ command: CommandPaletteCommand) -> Bool {
    switch command {
    case .newSession:
      Task { await sessions.createSessionInCurrentContext() }
    case .newSessionInWorkspace(let workspaceID):
      guard sessions.workspaces.contains(where: { $0.workspaceId == workspaceID }) else {
        return skipped(.run(command))
      }
      Task { await sessions.createSession(in: workspaceID) }
    case .newWorkspace:
      newWorkspace()
    case .splitRight:
      Task { await sessions.split(.right) }
    case .splitDown:
      Task { await sessions.split(.down) }
    case .closeShell(let shellID):
      guard sessions.focusedShellID == shellID else { return skipped(.run(command)) }
      Task { await sessions.requestCloseShell(shellID) }
    case .closeSession(let sessionID):
      guard sessions.selectedSessionID == sessionID else { return skipped(.run(command)) }
      Task { await sessions.requestCloseSession(sessionID) }
    case .toggleSidebar:
      toggleSidebar()
    case .openSettings:
      openSettings()
    }
    return true
  }

  private func skipped(_ action: CommandPaletteAction) -> Bool {
    AxoTrace.commands.notice(
      "event=palette.action_skipped reason=target_changed action=\(String(describing: action), privacy: .public)")
    return false
  }
}

extension TerminalSessionsModel {
  /// What the palette lists, as of now.
  func commandPaletteContext(homeDirectory: String = NSHomeDirectory()) -> CommandPaletteContext {
    CommandPaletteContext(
      sessions: sidebarOrderedSessions,
      workspaces: workspaces,
      recentSessionIDs: recentSessionIDs,
      selectedSessionID: selectedSessionID,
      focusedShellID: focusedShellID,
      availability: commandAvailability,
      homeDirectory: homeDirectory)
  }
}
