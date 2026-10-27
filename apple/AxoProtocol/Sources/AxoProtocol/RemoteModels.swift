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

  private enum CodingKeys: String, CodingKey { case hostId, hostGeneration }

  /// The relay compares identities as text, and its identities are lowercase; `UUID` encodes
  /// uppercase by default, which the relay reads as a different host ("Wrong host").
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hostId.uuidString.lowercased(), forKey: .hostId)
    try container.encode(hostGeneration.uuidString.lowercased(), forKey: .hostGeneration)
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
  /// The Home Workspace, which is listed first.
  public let isHome: Bool

  public init(workspaceId: UUID, name: String, isHome: Bool = false) {
    self.workspaceId = workspaceId
    self.name = name
    self.isHome = isHome
  }

  private enum CodingKeys: String, CodingKey {
    case workspaceId, name
    case isHome = "home"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workspaceId = try container.decode(UUID.self, forKey: .workspaceId)
    name = try container.decode(String.self, forKey: .name)
    isHome = try container.decodeIfPresent(Bool.self, forKey: .isHome) ?? false
  }
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
  /// A Pi event: what the agent said, did or finished. The relay also stores them as history.
  case piEvent(host: RemoteHostRef, sessionID: SessionID, event: PiEventRecord)

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
    case sequence, data, name, streamId
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
          event: PiEventRecord(
            streamId: try inner.decode(UUID.self, forKey: .streamId),
            sequence: try inner.decode(UInt64.self, forKey: .sequence),
            name: try inner.decode(String.self, forKey: .name),
            data: try inner.decodeIfPresent(JSONValue.self, forKey: .data) ?? .null))
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

/// One thing Pi did, in the order Pi did it: `sequence` rises within its `streamId`.
public struct PiEventRecord: Equatable, Sendable {
  public let streamId: UUID
  public let sequence: UInt64
  public let name: String
  public let data: JSONValue

  public init(streamId: UUID, sequence: UInt64, name: String, data: JSONValue) {
    self.streamId = streamId
    self.sequence = sequence
    self.name = name
    self.data = data
  }
}

/// A Pi event as the relay stored it, for reading a conversation from the start.
public struct StoredPiEvent: Decodable, Equatable, Sendable {
  public let id: Int64
  public let streamId: UUID
  public let sequence: UInt64
  public let name: String
  public let data: JSONValue
  public let receivedAt: Int64

  public var record: PiEventRecord {
    PiEventRecord(streamId: streamId, sequence: sequence, name: name, data: data)
  }
}

/// A page of stored events; `next` is where the following page starts, or nil at the end.
public struct PiEventPage: Decodable, Equatable, Sendable {
  public let events: [StoredPiEvent]
  public let next: Int64?

  public init(events: [StoredPiEvent], next: Int64?) {
    self.events = events
    self.next = next
  }
}
