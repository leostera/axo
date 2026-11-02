import Foundation

/// Another Mac of the account, as this Mac follows it (RFD0024).
public struct PeerHost: Decodable, Equatable, Identifiable, Sendable {
  public let hostId: String
  public let label: String
  public let online: Bool

  public var id: String { hostId }

  public init(hostId: String, label: String, online: Bool) {
    self.hostId = hostId
    self.label = label
    self.online = online
  }
}

/// Another Mac's Session: its record as a local one would be, and the Mac it runs on. Its shells
/// are this Mac's pane on it, when one is open.
public struct PeerSession: Decodable, Equatable, Sendable {
  public let hostId: String
  public let session: TerminalSession

  public init(hostId: String, session: TerminalSession) {
    self.hostId = hostId
    self.session = session
  }

  private enum CodingKeys: String, CodingKey { case hostId }

  /// The wire has the record's fields and `hostId` side by side.
  public init(from decoder: Decoder) throws {
    hostId = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .hostId)
    session = try TerminalSession(from: decoder)
  }
}

public struct PeerSessionList: Decodable, Equatable, Sendable {
  /// Whether this Mac follows the account now; the list is the last it had otherwise.
  public let connected: Bool
  public let hosts: [PeerHost]
  public let sessions: [PeerSession]

  public init(connected: Bool, hosts: [PeerHost], sessions: [PeerSession]) {
    self.connected = connected
    self.hosts = hosts
    self.sessions = sessions
  }
}
