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
  /// Axod asks clients to show this session, for example after `/resume`.
  case sessionFocus(sessionID: SessionID)
  /// Remote-access connection state changed.
  case relayStatus(RemoteAccessStatus)
  /// The other Macs or their Sessions changed, or a pane on one opened or closed: read
  /// `axo.peer.sessions.list` again (RFD0024).
  case peerSessionsChanged
  /// An agent or a tool asks the person (RFD0029): show it until it is resolved.
  case elicitationRequested(Elicitation)
  /// Answered here or elsewhere, nobody answered in time, or the asker went away.
  case elicitationResolved(id: String, sessionID: SessionID, action: ElicitationAction)
  /// Axod has finished starting: the Pis it started at launch are up. Sent once per Axod;
  /// `DaemonHealth.ready` says the same to a client that subscribed later.
  case daemonReady
  /// Earlier events were discarded; the consumer must resynchronize from a fresh listing.
  case subscriptionLagged
  /// An event type this client does not understand. Ignored for forward compatibility.
  case unknown(type: String)

  private enum CodingKeys: String, CodingKey {
    case type, session, sessionId, shellId, activity, sequence, data, status
    case elicitation, id, action
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
        throw DecodingError.dataCorruptedError(
          forKey: .data, in: container, debugDescription: "terminal output was not base64")
      }
      self = .terminalOutput(
        sessionID: try container.decode(SessionID.self, forKey: .sessionId),
        shellID: try container.decode(ShellID.self, forKey: .shellId),
        sequence: try container.decode(UInt64.self, forKey: .sequence),
        data: data)
    case "relay.status":
      self = .relayStatus(try container.decode(RemoteAccessStatus.self, forKey: .status))
    case "session.focus":
      self = .sessionFocus(sessionID: try container.decode(SessionID.self, forKey: .sessionId))
    case "peer.sessions.changed":
      self = .peerSessionsChanged
    case "elicitation.requested":
      self = .elicitationRequested(try container.decode(Elicitation.self, forKey: .elicitation))
    case "elicitation.resolved":
      self = .elicitationResolved(
        id: try container.decode(String.self, forKey: .id),
        sessionID: try container.decode(SessionID.self, forKey: .sessionId),
        action: try container.decode(ElicitationAction.self, forKey: .action))
    case "daemon.ready":
      self = .daemonReady
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
