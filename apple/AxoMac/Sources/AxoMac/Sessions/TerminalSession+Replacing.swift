import AxoRPC

extension TerminalSession {
  /// A copy with app-owned shell membership; all other fields are the daemon's.
  func replacing(shells: [TerminalShell]) -> TerminalSession {
    TerminalSession(
      id: id,
      initialPwd: initialPwd,
      shells: shells,
      layout: layout,
      sessionUuid: sessionUuid,
      piSessionFile: piSessionFile,
      piSessionId: piSessionId,
      workspaceId: workspaceId,
      workspaceName: workspaceName,
      name: name,
      manualName: manualName,
      emoji: emoji,
      status: status
    )
  }
}
