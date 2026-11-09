import AppKit
import AxoProtocol

/// What "Copy Session Info" puts on the clipboard: enough for a person to paste into another
/// Session so its agent can reach this one, by ID through the axo MCP tools, and read what it
/// has been doing in its transcript.
enum SessionInfo {
  /// `hostLabel` names the Mac another Mac's Session runs on; nil for this Mac's. Its
  /// transcript lives on that Mac, so it is left out.
  static func text(for session: TerminalSession, hostLabel: String? = nil) -> String {
    var lines = ["Axo Session \"\(session.displayName)\""]
    lines.append("Session ID: \(session.id.rawValue)")
    lines.append("Folder: \(session.folder)")
    if let hostLabel {
      lines.append("Runs on: \(hostLabel)")
    } else if let transcript = session.piSessionFile {
      lines.append("Transcript: \(transcript)")
    }
    lines.append("")
    var reach =
      "To message it, call the axo MCP tool session_prompt with sessionId \"\(session.id.rawValue)\"."
    if hostLabel == nil, session.piSessionFile != nil {
      reach += " To see what it has been doing, read its transcript (JSONL)."
    }
    lines.append(reach)
    return lines.joined(separator: "\n")
  }

  static func copy(_ session: TerminalSession, hostLabel: String? = nil) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text(for: session, hostLabel: hostLabel), forType: .string)
  }
}
