import Foundation

/// A host as the relay names it: its identity and the generation of its current run. Calls
/// carry both, so an answer for an older run of the host is refused ("Stale host").
public struct RemoteHostRef: Codable, Hashable, Sendable {
  public let hostId: UUID
  public let hostGeneration: UUID

  public init(hostId: UUID, hostGeneration: UUID) {
    self.hostId = hostId
    self.hostGeneration = hostGeneration
  }
}

public enum RemoteHostStatus: String, Decodable, Equatable, Sendable {
  case online
  case offline
}

public enum RemoteSessionStatus: String, Decodable, Equatable, Sendable {
  case starting
  case ready
  case working
  case needsAttention
  case unavailable
}

public struct RemoteShell: Decodable, Hashable, Sendable {
  public let shellId: ShellID
}

/// A Session as an account sees it through the relay: terminals only, no local paths.
public struct RemoteSession: Decodable, Equatable, Sendable {
  public let hostId: UUID
  public let sessionId: SessionID
  public let sessionUuid: UUID?
  public let workspaceId: UUID?
  public let workspaceName: String?
  public let name: String?
  public let emoji: String?
  public let status: RemoteSessionStatus?
  public let hasAgent: Bool?
  public let shells: [RemoteShell]
  public let layout: SessionLayout?
  public let updatedAt: String

  public var displayName: String { name ?? "Session \(sessionId)" }
}

public struct RemoteHost: Decodable, Equatable, Sendable {
  public let hostId: UUID
  public let hostGeneration: UUID
  public let label: String
  public let hostKind: String
  public let status: RemoteHostStatus
  public let stale: Bool
  public let lastSeenAt: String
  public let sessions: [RemoteSession]

  public var reference: RemoteHostRef { RemoteHostRef(hostId: hostId, hostGeneration: hostGeneration) }
}

public struct RemoteHostList: Decodable, Equatable, Sendable {
  public let hosts: [RemoteHost]
}

public struct RemoteWorkspace: Decodable, Equatable, Sendable {
  public let workspaceId: UUID
  public let name: String
}

public struct RemoteWorkspaceList: Decodable, Equatable, Sendable {
  public let workspaces: [RemoteWorkspace]
}

/// What the relay pushes about a host the client subscribed to.
public enum RemoteHostEvent: Equatable, Sendable {
  /// The host came online or went offline.
  case presence(host: RemoteHostRef, status: RemoteHostStatus)
  case sessionSnapshot(host: RemoteHostRef, session: RemoteSession)
  case sessionRemoved(host: RemoteHostRef, sessionID: SessionID)
  case shellActivity(
    host: RemoteHostRef, sessionID: SessionID, shellID: ShellID, activity: TerminalShellActivity)
  case terminalOutput(
    host: RemoteHostRef, sessionID: SessionID, shellID: ShellID, sequence: UInt64, data: Data)
  /// A Pi event; the relay stores these for history. Clients may ignore them.
  case piEvent(host: RemoteHostRef, sessionID: SessionID, name: String)

  public var host: RemoteHostRef {
    switch self {
    case .presence(let host, _), .sessionSnapshot(let host, _), .sessionRemoved(let host, _),
      .shellActivity(let host, _, _, _), .terminalOutput(let host, _, _, _, _),
      .piEvent(let host, _, _):
      host
    }
  }
}

/// The `params` of an `axo.host.event` notification.
public struct RemoteHostNotification: Decodable, Equatable, Sendable {
  public let subscriptionId: UUID
  public let event: RemoteHostEvent

  private enum CodingKeys: String, CodingKey { case subscriptionId, event }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    subscriptionId = try container.decode(UUID.self, forKey: .subscriptionId)
    event = try container.decode(RemoteHostEvent.self, forKey: .event)
  }
}

extension RemoteHostEvent: Decodable {
  private enum CodingKeys: String, CodingKey {
    case type, hostId, hostGeneration, status, event, snapshot, sessionId, shellId, activity
    case sequence, data, name
  }

  public init(from decoder: Decoder) throws {
    let outer = try decoder.container(keyedBy: CodingKeys.self)
    let host = RemoteHostRef(
      hostId: try outer.decode(UUID.self, forKey: .hostId),
      hostGeneration: try outer.decode(UUID.self, forKey: .hostGeneration))
    switch try outer.decode(String.self, forKey: .type) {
    case "host.presence":
      self = .presence(host: host, status: try outer.decode(RemoteHostStatus.self, forKey: .status))
    case "host.data":
      let inner = try outer.nestedContainer(keyedBy: CodingKeys.self, forKey: .event)
      switch try inner.decode(String.self, forKey: .type) {
      case "session.snapshot":
        let session = try inner.decode(RemoteSession.self, forKey: .snapshot)
        guard session.hostId == host.hostId else {
          throw DecodingError.dataCorruptedError(
            forKey: .snapshot, in: inner, debugDescription: "snapshot is for another host")
        }
        self = .sessionSnapshot(host: host, session: session)
      case "session.removed":
        self = .sessionRemoved(host: host, sessionID: try inner.decode(SessionID.self, forKey: .sessionId))
      case "shell.activity":
        self = .shellActivity(
          host: host,
          sessionID: try inner.decode(SessionID.self, forKey: .sessionId),
          shellID: try inner.decode(ShellID.self, forKey: .shellId),
          activity: try inner.decode(TerminalShellActivity.self, forKey: .activity))
      case "terminal.output":
        guard let data = Data(base64Encoded: try inner.decode(String.self, forKey: .data)) else {
          throw DecodingError.dataCorruptedError(
            forKey: .data, in: inner, debugDescription: "terminal output was not base64")
        }
        self = .terminalOutput(
          host: host,
          sessionID: try inner.decode(SessionID.self, forKey: .sessionId),
          shellID: try inner.decode(ShellID.self, forKey: .shellId),
          sequence: try inner.decode(UInt64.self, forKey: .sequence),
          data: data)
      case "pi.event":
        self = .piEvent(
          host: host,
          sessionID: try inner.decode(SessionID.self, forKey: .sessionId),
          name: try inner.decode(String.self, forKey: .name))
      case let type:
        throw DecodingError.dataCorruptedError(
          forKey: .type, in: inner, debugDescription: "unknown host data event \(type)")
      }
    case let type:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: outer, debugDescription: "unknown host event \(type)")
    }
  }
}
