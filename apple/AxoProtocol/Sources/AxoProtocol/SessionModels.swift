import Foundation

public enum TerminalSessionStatus: String, Decodable, Equatable, Sendable {
  case starting
  case ready
  case working
  case needsAttention
  case unavailable
}

public struct TerminalSessionListSnapshot: Decodable, Sendable {
  public let sessions: [TerminalSession]
  public let resumeSessionId: SessionID?

  public init(sessions: [TerminalSession], resumeSessionId: SessionID? = nil) {
    self.sessions = sessions
    self.resumeSessionId = resumeSessionId
  }
}

public struct TerminalSession: Decodable, Equatable, Identifiable, Sendable {
  public let id: SessionID
  public let sessionUuid: String?
  public let piSessionFile: String?
  public let piSessionId: String?
  public let workspaceId: String?
  public let workspaceName: String?
  public let name: String?
  public let manualName: String?
  public let emoji: String?
  /// Unix timestamp in seconds of the latest completed user or assistant message.
  public let lastMessageAt: Int64?
  public let status: TerminalSessionStatus?
  public let initialPwd: String
  public let shells: [TerminalShell]
  public let layout: SessionLayout?

  public var displayName: String { manualName ?? name ?? "Session \(id)" }

  public init(
    id: SessionID,
    initialPwd: String,
    shells: [TerminalShell],
    layout: SessionLayout? = nil,
    sessionUuid: String? = nil,
    piSessionFile: String? = nil,
    piSessionId: String? = nil,
    workspaceId: String? = nil,
    workspaceName: String? = nil,
    name: String? = nil,
    manualName: String? = nil,
    emoji: String? = nil,
    lastMessageAt: Int64? = nil,
    status: TerminalSessionStatus? = nil
  ) {
    self.id = id
    self.sessionUuid = sessionUuid
    self.piSessionFile = piSessionFile
    self.piSessionId = piSessionId
    self.workspaceId = workspaceId
    self.workspaceName = workspaceName
    self.name = name
    self.manualName = manualName
    self.emoji = emoji
    self.lastMessageAt = lastMessageAt
    self.status = status
    self.initialPwd = initialPwd
    self.shells = shells
    self.layout = layout
  }
}

/// What runs in a pane.
public enum PaneRole: String, Decodable, Equatable, Sendable {
  /// The session's Pi agent.
  case pi
  /// The user's shell.
  case terminal
}

/// Whether a pane can be attached. On the wire this is `available` plus `availabilityReason`;
/// the reason is present exactly when the pane is unavailable, so a pane that is "available
/// with a reason" or "unavailable without one" cannot be represented.
public enum PaneAvailability: Equatable, Sendable {
  case available
  case unavailable(reason: String)
}

public struct TerminalShell: Decodable, Equatable, Identifiable, Sendable {
  public let id: ShellID
  public let paneId: String?
  public let role: PaneRole
  public let processId: UInt32
  public let initialPwd: String
  public let ptyDevice: String
  public let attachSocketPath: String
  public let availability: PaneAvailability

  public var isAvailable: Bool { availability == .available }
  public var isPi: Bool { role == .pi }

  public init(
    id: ShellID,
    processId: UInt32,
    initialPwd: String,
    ptyDevice: String,
    attachSocketPath: String,
    paneId: String? = nil,
    role: PaneRole = .terminal,
    availability: PaneAvailability = .available
  ) {
    self.id = id
    self.paneId = paneId
    self.role = role
    self.processId = processId
    self.initialPwd = initialPwd
    self.ptyDevice = ptyDevice
    self.attachSocketPath = attachSocketPath
    self.availability = availability
  }

  private enum CodingKeys: String, CodingKey {
    case id, paneId, role, processId, initialPwd, ptyDevice, attachSocketPath, available,
      availabilityReason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(ShellID.self, forKey: .id)
    paneId = try container.decodeIfPresent(String.self, forKey: .paneId)
    role = try container.decode(PaneRole.self, forKey: .role)
    processId = try container.decode(UInt32.self, forKey: .processId)
    initialPwd = try container.decode(String.self, forKey: .initialPwd)
    ptyDevice = try container.decode(String.self, forKey: .ptyDevice)
    attachSocketPath = try container.decode(String.self, forKey: .attachSocketPath)
    let available = try container.decode(Bool.self, forKey: .available)
    let reason = try container.decodeIfPresent(String.self, forKey: .availabilityReason)
    switch (available, reason) {
    case (true, nil):
      availability = .available
    case (false, let reason?) where !reason.isEmpty:
      availability = .unavailable(reason: reason)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .availabilityReason, in: container,
        debugDescription: "availabilityReason must be present exactly when a pane is unavailable")
    }
  }
}

public struct WorkspaceRecord: Decodable, Equatable, Identifiable, Sendable {
  public let workspaceId: String
  public let name: String
  public let directoryPath: String
  public var id: String { workspaceId }

  public init(workspaceId: String, name: String, directoryPath: String) {
    self.workspaceId = workspaceId
    self.name = name
    self.directoryPath = directoryPath
  }
}

public struct ArchivedWorkspace: Decodable, Equatable, Sendable {
  public let archivedWorkspaceId: String
  public let archivedSessionIds: [SessionID]
}

public struct CreatedWorkspace: Decodable, Equatable, Sendable {
  public let workspace: WorkspaceRecord
  public let session: TerminalSession
}

public struct ClosedTerminalSession: Decodable, Equatable, Sendable {
  public let archivedSessionId: SessionID
  public let replacement: TerminalSession?
}

/// Whether closing a shell would interrupt work (`axo.shell.busy`).
public struct TerminalShellBusy: Decodable, Equatable, Sendable {
  public let busy: Bool
  /// The foreground process name, a presentation hint only.
  public let foregroundProcess: String?

  public init(busy: Bool, foregroundProcess: String?) {
    self.busy = busy
    self.foregroundProcess = foregroundProcess
  }
}

public struct ClosedTerminalShell: Decodable, Equatable, Sendable {
  public let archivedShellId: ShellID
  public let archivedSessionId: SessionID?
  public let replacement: TerminalSession?
}
