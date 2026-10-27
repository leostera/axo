import AxoProtocol
import Foundation

/// A pane close (⌘W) waiting for the user: the pane is busy, or Axod couldn't say.
struct ShellCloseConfirmation: Equatable, Identifiable {
  enum Reason: Equatable {
    case runningProcess(String?)
    case piWorking
    case unknown

    /// Why closing a pane needs confirmation; `nil` means close it at once. When Axod can't say
    /// whether the pane is busy (`busy == nil`), ask rather than guess.
    init?(closing role: PaneRole, busy: TerminalShellBusy?) {
      switch (busy, role) {
      case (nil, _): self = .unknown
      case (let busy?, _) where !busy.busy: return nil
      case (_, .pi): self = .piWorking
      case (let busy?, _): self = .runningProcess(busy.foregroundProcess)
      }
    }
  }

  let shellID: ShellID
  let reason: Reason

  var id: ShellID { shellID }
}

/// Closing the last Session of a Workspace archives the Workspace, so it waits for the user.
struct WorkspaceArchiveConfirmation: Equatable, Identifiable {
  let workspaceID: String
  let workspaceName: String
  let sessionID: SessionID

  var id: String { workspaceID }

  /// Whether, when the user answers, the Workspace is still listed and this is still its only
  /// Session. Anything else changed what the user agreed to.
  func stillApplies(sessions: [TerminalSession], workspaces: [WorkspaceRecord]) -> Bool {
    sessions.filter { $0.workspaceId == workspaceID }.map(\.id) == [sessionID]
      && workspaces.contains { $0.workspaceId == workspaceID }
  }
}

/// What closing a Session takes.
enum SessionClosePlan: Equatable {
  case close
  /// It is its Workspace's last Session: closing archives the Workspace, so ask first. Never for
  /// Home, which cannot be archived.
  case confirmArchive(WorkspaceArchiveConfirmation)
  /// It is the last Session of a Workspace Axo doesn't list; refuse rather than archive blind.
  case workspaceUnavailable

  init(closing session: TerminalSession, sessions: [TerminalSession], workspaces: [WorkspaceRecord]) {
    guard let workspaceID = session.workspaceId,
      sessions.filter({ $0.workspaceId == workspaceID }).count == 1
    else {
      self = .close
      return
    }
    guard let workspace = workspaces.first(where: { $0.workspaceId == workspaceID }) else {
      self = .workspaceUnavailable
      return
    }
    // Home is never archived: Axod replaces its last Session instead.
    guard !workspace.isHome else {
      self = .close
      return
    }
    self = .confirmArchive(
      WorkspaceArchiveConfirmation(
        workspaceID: workspaceID, workspaceName: workspace.name, sessionID: session.id))
  }
}
