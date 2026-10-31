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
  public let workspaceId: UUID?
  public let workspaceName: String?
  public let name: String?
  public let emoji: String?
  public let status: RemoteSessionStatus?
  public let hasAgent: Bool?
  public let shells: [RemoteShell]
  public let layout: SessionLayout?
  /// When this snapshot was sent, not when the Session was last active.
  public let updatedAt: String
  /// Unix seconds of the Session's latest completed user or assistant message.
  public let lastMessageAt: Int64?
  /// Unix seconds when the Session was created.
  public let createdAt: Int64?

  public var displayName: String { name ?? "Session" }

  public init(
    hostId: UUID, sessionId: SessionID, workspaceId: UUID? = nil, workspaceName: String? = nil,
    name: String? = nil, emoji: String? = nil, status: RemoteSessionStatus? = nil, hasAgent: Bool? = nil,
    shells: [RemoteShell] = [], layout: SessionLayout? = nil, updatedAt: String = "",
    lastMessageAt: Int64? = nil, createdAt: Int64? = nil
  ) {
    self.hostId = hostId
    self.sessionId = sessionId
    self.workspaceId = workspaceId
    self.workspaceName = workspaceName
    self.name = name
    self.emoji = emoji
    self.status = status
    self.hasAgent = hasAgent
    self.shells = shells
    self.layout = layout
    self.updatedAt = updatedAt
    self.lastMessageAt = lastMessageAt
    self.createdAt = createdAt
  }

  /// A Session as the account's client lists it (RFD0018): what the host says of it, without
  /// terminals, which stay on the Mac.
  public init(_ listed: ClientSession) {
    self.init(
      hostId: listed.hostId, sessionId: listed.sessionId, workspaceId: listed.metadata.workspaceId,
      workspaceName: listed.metadata.workspaceName, name: listed.metadata.name, emoji: listed.metadata.emoji,
      status: listed.status, hasAgent: listed.metadata.hasAgent,
      lastMessageAt: listed.metadata.lastMessageAt, createdAt: listed.metadata.createdAt)
  }
}

public struct RemoteHost: Equatable, Sendable {
  public let hostId: UUID
  public let hostGeneration: UUID
  public let label: String
  public let hostKind: String
  public let status: RemoteHostStatus
  public let stale: Bool
  public let lastSeenAt: String
  public let sessions: [RemoteSession]

  public var reference: RemoteHostRef { RemoteHostRef(hostId: hostId, hostGeneration: hostGeneration) }

  public init(
    hostId: UUID, hostGeneration: UUID, label: String, hostKind: String = "macos", status: RemoteHostStatus,
    stale: Bool = false, lastSeenAt: String = "", sessions: [RemoteSession]
  ) {
    self.hostId = hostId
    self.hostGeneration = hostGeneration
    self.label = label
    self.hostKind = hostKind
    self.status = status
    self.stale = stale
    self.lastSeenAt = lastSeenAt
    self.sessions = sessions
  }

  /// A host as the account's client lists it, with the Sessions listed for it.
  public init(_ listed: ClientHost, sessions: [RemoteSession]) {
    self.init(
      hostId: listed.hostId, hostGeneration: listed.hostGeneration, label: listed.label, hostKind: listed.hostKind,
      status: listed.online ? .online : .offline, stale: !listed.online, lastSeenAt: listed.lastSeenAt,
      sessions: sessions)
  }
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

// MARK: - The account's client (RFD0018)

/// What a client lists a Session by. The host owns it and raises its version on every change.
public struct SessionMetadata: Decodable, Equatable, Sendable {
  public let name: String?
  public let emoji: String?
  public let workspaceId: UUID?
  public let workspaceName: String?
  public let hasAgent: Bool
  /// Unix seconds.
  public let createdAt: Int64?
  /// Unix seconds of the latest completed user or assistant message.
  public let lastMessageAt: Int64?
  /// Archived on the Mac, deleted there, or missing from its listing: the cloud never deletes.
  public let archived: Bool

  public init(
    name: String? = nil, emoji: String? = nil, workspaceId: UUID? = nil, workspaceName: String? = nil,
    hasAgent: Bool = true, createdAt: Int64? = nil, lastMessageAt: Int64? = nil, archived: Bool = false
  ) {
    self.name = name
    self.emoji = emoji
    self.workspaceId = workspaceId
    self.workspaceName = workspaceName
    self.hasAgent = hasAgent
    self.createdAt = createdAt
    self.lastMessageAt = lastMessageAt
    self.archived = archived
  }
}

/// One of the account's hosts, as its client follows it.
public struct ClientHost: Decodable, Equatable, Sendable {
  public let hostId: UUID
  public let hostGeneration: UUID
  public let label: String
  public let hostKind: String
  public let online: Bool
  public let lastSeenAt: String

  public init(hostId: UUID, hostGeneration: UUID, label: String, hostKind: String = "macos", online: Bool, lastSeenAt: String = "") {
    self.hostId = hostId
    self.hostGeneration = hostGeneration
    self.label = label
    self.hostKind = hostKind
    self.online = online
    self.lastSeenAt = lastSeenAt
  }

  public var reference: RemoteHostRef { RemoteHostRef(hostId: hostId, hostGeneration: hostGeneration) }
}

/// One Session of one host, as its client lists it: `head` records are in the cloud, in `epoch`.
public struct ClientSession: Decodable, Equatable, Sendable {
  public let hostId: UUID
  public let sessionId: SessionID
  public let metadata: SessionMetadata
  /// Nil until the first record lands.
  public let epoch: Int64?
  public let head: Int64
  public let status: RemoteSessionStatus?

  public init(hostId: UUID, sessionId: SessionID, metadata: SessionMetadata, epoch: Int64? = nil, head: Int64 = 0, status: RemoteSessionStatus? = nil) {
    self.hostId = hostId
    self.sessionId = sessionId
    self.metadata = metadata
    self.epoch = epoch
    self.head = head
    self.status = status
  }
}

/// A durable record as clients see it: one line of the agent's transcript. Only the format
/// adapter knows what is in `line`.
public struct ClientRecord: Decodable, Equatable, Sendable {
  /// The record's place in the cloud copy: the client's resume point within one epoch.
  public let cursor: Int64
  public let id: String?
  public let format: String
  public let line: String
  public let hash: String

  public init(cursor: Int64, id: String?, format: String = "pi/3", line: String, hash: String = "sha256:" + String(repeating: "0", count: 64)) {
    self.cursor = cursor
    self.id = id
    self.format = format
    self.line = line
    self.hash = hash
  }
}

/// The newest snapshot of one progress slot: `"message"` for the reply being written,
/// `"question"` for what the agent asks, or a running tool's call id.
public struct ProgressSnapshot: Decodable, Equatable, Sendable {
  public let slot: String
  /// Null when the slot is cleared.
  public let snapshot: JSONValue

  public init(slot: String, snapshot: JSONValue) {
    self.slot = slot
    self.snapshot = snapshot
  }

  private enum CodingKeys: String, CodingKey { case slot, snapshot }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    slot = try container.decode(String.self, forKey: .slot)
    snapshot = try container.decodeIfPresent(JSONValue.self, forKey: .snapshot) ?? .null
  }
}

/// The answer to `axo.client.hello` and `axo.client.refresh`: every host and Session.
public struct ClientHello: Decodable, Equatable, Sendable {
  public let hosts: [ClientHost]
  public let sessions: [ClientSession]

  public init(hosts: [ClientHost], sessions: [ClientSession]) {
    self.hosts = hosts
    self.sessions = sessions
  }
}

/// The answer to `axo.client.session.open`.
public struct ClientOpenResult: Decodable, Equatable, Sendable {
  /// Nil while the cloud holds no records for the Session.
  public let epoch: Int64?
  public let records: [ClientRecord]
  /// The last cursor the client holds after taking `records`.
  public let cursor: Int64
  /// Records below this cursor exist; nil when the client holds the start.
  public let older: Int64?
  public let progress: [ProgressSnapshot]

  public init(epoch: Int64?, records: [ClientRecord], cursor: Int64, older: Int64?, progress: [ProgressSnapshot] = []) {
    self.epoch = epoch
    self.records = records
    self.cursor = cursor
    self.older = older
    self.progress = progress
  }
}

/// Records just below a `before`, oldest first, and the `before` of the next older page.
public struct ClientOlderPage: Decodable, Equatable, Sendable {
  public let epoch: Int64?
  public let records: [ClientRecord]
  public let older: Int64?

  public init(epoch: Int64?, records: [ClientRecord], older: Int64?) {
    self.epoch = epoch
    self.records = records
    self.older = older
  }
}

/// What the account's socket tells its client as it happens.
public enum AccountEvent: Equatable, Sendable {
  /// A new connection said hello: every host and Session, as they are now.
  case hello(ClientHello)
  /// The whole host list, whenever a host's presence changes.
  case hosts([ClientHost])
  /// Sessions of one host that changed.
  case sessions(hostID: UUID, [ClientSession])
  /// The next records of an open Session; acknowledge `cursor` once they are taken.
  case records(sessionID: SessionID, epoch: Int64, [ClientRecord], cursor: Int64)
  /// A progress slot's newest snapshot, or null when it is cleared.
  case progress(sessionID: SessionID, slot: String, snapshot: JSONValue)
  /// The cloud copy was cut back: drop every record after `keep`; `epoch` follows.
  case reset(sessionID: SessionID, epoch: Int64, keep: Int64)
}
