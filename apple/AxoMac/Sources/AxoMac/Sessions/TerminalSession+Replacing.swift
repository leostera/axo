import AxoProtocol

extension TerminalSession {
  /// A copy with app-owned shell membership; all other fields are the daemon's.
  func replacing(shells: [TerminalShell]) -> TerminalSession {
    TerminalSession(
      id: id,
      folder: folder,
      shells: shells,
      layout: layout,
      piSessionFile: piSessionFile,
      piSessionId: piSessionId,
      name: name,
      manualName: manualName,
      emoji: emoji,
      lastMessageAt: lastMessageAt,
      createdAt: createdAt,
      status: status
    )
  }
}
