import Foundation

/// Parsed absolute local path; filesystem usability remains the daemon's responsibility.
public struct LocalDirectoryPath: Encodable, Equatable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("/"), rawValue.utf8.count <= 16384, !rawValue.utf8.contains(0) else { return nil }
        self.rawValue = rawValue
    }

    public init?(selectedURL: URL) {
        guard selectedURL.isFileURL else { return nil }
        self.init(rawValue: selectedURL.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Local-only admission-time empty-work predicate; no directory/argv/workspace authority.
public struct EmptyStartupSessionParameters: Encodable, Sendable {
    public let target: MachineTarget
    public let commandId: UUID
    public let expectedRevision: WorkRevision
    public let name: String
    public init(target: MachineTarget, commandId: UUID, expectedRevision: WorkRevision, name: String) {
        self.target = target; self.commandId = commandId
        self.expectedRevision = expectedRevision; self.name = name
    }
}

/// Local-only folder selection authority; cloud requests never accept filesystem paths.
public struct LocalWorkspaceCreateParameters: Encodable, Sendable {
    public let target: MachineTarget
    public let commandId: UUID
    public let expectedRevision: WorkRevision
    public let directoryPath: LocalDirectoryPath
    public let name: String
    public let initialSessionName: String?

    public init(target: MachineTarget, commandId: UUID, expectedRevision: WorkRevision, directoryPath: LocalDirectoryPath, name: String, initialSessionName: String? = nil) {
        self.target = target
        self.commandId = commandId
        self.expectedRevision = expectedRevision
        self.directoryPath = directoryPath
        self.name = name
        self.initialSessionName = initialSessionName
    }
}

public struct LocalWorkspaceMutationResult: Equatable, Sendable {
    public let hostGeneration: UUID
    public let revision: WorkRevision
    public let workspace: WorkWorkspaceRecord
    public let session: WorkSessionRecord?
    public init(hostGeneration: UUID, revision: WorkRevision, workspace: WorkWorkspaceRecord, session: WorkSessionRecord?) {
        self.hostGeneration = hostGeneration
        self.revision = revision
        self.workspace = workspace
        self.session = session
    }
}
