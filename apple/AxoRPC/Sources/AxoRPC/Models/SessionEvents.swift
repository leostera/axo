import Foundation

public enum TerminalShellActivity: String, Decodable, Equatable, Sendable {
  case started
  case exited
  case attached
  case detached
}

public enum TerminalSessionEvent: Decodable, Equatable, Sendable {
  case sessionSnapshot(TerminalSession)
  case sessionRemoved(sessionID: SessionID)
  case shellActivity(sessionID: SessionID, shellID: ShellID, activity: TerminalShellActivity)
  case terminalOutput(sessionID: SessionID, shellID: ShellID, sequence: UInt64, data: Data)
  /// A workspace was created, renamed or archived; reload the workspace list.
  case workspaceChanged(workspaceID: String)
  /// Axod asks clients to show this session, for example after `/resume`.
  case sessionFocus(sessionID: SessionID)
  /// Earlier events were discarded; the consumer must resynchronize from a fresh listing.
  case subscriptionLagged
  /// An event type this client does not understand. Ignored for forward compatibility.
  case unknown(type: String)

  private enum CodingKeys: String, CodingKey {
    case type, session, sessionId, shellId, activity, sequence, data, workspaceId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "session.snapshot":
      self = .sessionSnapshot(try container.decode(TerminalSession.self, forKey: .session))
    case "session.removed":
      self = .sessionRemoved(sessionID: try container.decode(SessionID.self, forKey: .sessionId))
    case "shell.activity":
      self = .shellActivity(
        sessionID: try container.decode(SessionID.self, forKey: .sessionId),
        shellID: try container.decode(ShellID.self, forKey: .shellId),
        activity: try container.decode(TerminalShellActivity.self, forKey: .activity))
    case "terminal.output":
      let encoded = try container.decode(String.self, forKey: .data)
      guard let data = Data(base64Encoded: encoded) else {
        throw UnixSocketRPCError.invalidResponse("terminal output was not base64")
      }
      self = .terminalOutput(
        sessionID: try container.decode(SessionID.self, forKey: .sessionId),
        shellID: try container.decode(ShellID.self, forKey: .shellId),
        sequence: try container.decode(UInt64.self, forKey: .sequence),
        data: data)
    case "workspace.changed":
      self = .workspaceChanged(workspaceID: try container.decode(String.self, forKey: .workspaceId))
    case "session.focus":
      self = .sessionFocus(sessionID: try container.decode(SessionID.self, forKey: .sessionId))
    case "subscription.lagged":
      self = .subscriptionLagged
    case let type:
      self = .unknown(type: type)
    }
  }
}

public struct TerminalSubscriptionID: Decodable, Equatable, Sendable {
  public let subscriptionId: String

  public init(subscriptionId: String) {
    self.subscriptionId = subscriptionId
  }
}
