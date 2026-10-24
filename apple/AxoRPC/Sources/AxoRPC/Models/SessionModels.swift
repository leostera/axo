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
  public let resumeSessionId: Int64?

  public init(sessions: [TerminalSession], resumeSessionId: Int64? = nil) {
    self.sessions = sessions
    self.resumeSessionId = resumeSessionId
  }
}

public struct TerminalSession: Decodable, Equatable, Identifiable, Sendable {
  public let id: Int64
  public let sessionUuid: String?
  public let piSessionFile: String?
  public let piSessionId: String?
  public let workspaceId: String?
  public let workspaceName: String?
  public let name: String?
  public let manualName: String?
  public let emoji: String?
  public let status: TerminalSessionStatus?
  public let initialPwd: String
  public let shells: [TerminalShell]
  public let layout: SessionLayout?

  public var displayName: String { manualName ?? name ?? "Session \(id)" }

  public init(
    id: Int64,
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
    self.status = status
    self.initialPwd = initialPwd
    self.shells = shells
    self.layout = layout
  }
}

public struct TerminalShell: Decodable, Equatable, Identifiable, Sendable {
  public let id: Int64
  public let paneId: String?
  public let role: String?
  public let processId: UInt32
  public let initialPwd: String
  public let ptyDevice: String
  public let attachSocketPath: String
  public let available: Bool?
  public let availabilityReason: String?

  public var isAvailable: Bool { available != false }

  public init(
    id: Int64,
    processId: UInt32,
    initialPwd: String,
    ptyDevice: String,
    attachSocketPath: String,
    paneId: String? = nil,
    role: String? = nil,
    available: Bool? = nil,
    availabilityReason: String? = nil
  ) {
    self.id = id
    self.paneId = paneId
    self.role = role
    self.processId = processId
    self.initialPwd = initialPwd
    self.ptyDevice = ptyDevice
    self.attachSocketPath = attachSocketPath
    self.available = available
    self.availabilityReason = availabilityReason
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
  public let archivedSessionIds: [Int64]
}

public struct CreatedWorkspace: Decodable, Equatable, Sendable {
  public let workspace: WorkspaceRecord
  public let session: TerminalSession
}

public struct ClosedTerminalSession: Decodable, Equatable, Sendable {
  public let archivedSessionId: Int64
  public let replacement: TerminalSession?
}

public struct ClosedTerminalShell: Decodable, Equatable, Sendable {
  public let archivedShellId: Int64
  public let archivedSessionId: Int64?
  public let replacement: TerminalSession?
}
