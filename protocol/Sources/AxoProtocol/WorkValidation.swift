import Foundation

/// Validation for work-record request parameters before they are sent to the daemon.
public enum AxoProtocolWorkRequestValidator {
    public static func validate(_ parameters: WorkspaceListParameters) throws {
        guard (1...AxoProtocol.maximumPageSize).contains(parameters.limit),
              matches(parameters.cursor, target: parameters.target, scope: .workspaces)
        else { throw invalid(AxoProtocol.Method.listWorkspaces) }
    }

    public static func validate(_ parameters: SessionListParameters) throws {
        let scope = WorkCursorScope.sessions(workspaceId: parameters.workspaceId)
        guard (1...AxoProtocol.maximumPageSize).contains(parameters.limit),
              matches(parameters.cursor, target: parameters.target, scope: scope)
        else { throw invalid(AxoProtocol.Method.listSessions) }
    }

    public static func validate(_ parameters: WorkspaceCreateParameters) throws {
        guard validName(parameters.name), validDirectoryID(parameters.directoryId),
              parameters.expectedRevision.rawValue < WorkRevision.maximumSafeInteger
        else { throw invalid(AxoProtocol.Method.createWorkspace) }
    }

    public static func validate(_ parameters: LocalWorkspaceCreateParameters) throws {
        guard validName(parameters.name), parameters.initialSessionName.map(validName) ?? true,
              parameters.expectedRevision.rawValue < WorkRevision.maximumSafeInteger
        else { throw invalid(AxoProtocol.Method.createLocalWorkspace) }
    }

    public static func validate(_ parameters: WorkspaceRenameParameters) throws {
        guard validName(parameters.name), parameters.expectedRevision.rawValue < WorkRevision.maximumSafeInteger
        else { throw invalid(AxoProtocol.Method.renameWorkspace) }
    }

    public static func validate(_ parameters: EmptyStartupSessionParameters) throws {
        guard validName(parameters.name), parameters.expectedRevision.rawValue < WorkRevision.maximumSafeInteger
        else { throw invalid(AxoProtocol.Method.createEmptyStartupSession) }
    }

    public static func validate(_ parameters: SessionCreateParameters) throws {
        guard validName(parameters.name), parameters.expectedRevision.rawValue < WorkRevision.maximumSafeInteger
        else { throw invalid(AxoProtocol.Method.createSession) }
    }

    public static func validate(_ parameters: SessionRenameParameters) throws {
        guard validName(parameters.name), parameters.expectedRevision.rawValue < WorkRevision.maximumSafeInteger
        else { throw invalid(AxoProtocol.Method.renameSession) }
    }

    private static func matches(_ cursor: WorkPageCursor?, target: MachineTarget, scope: WorkCursorScope) -> Bool {
        guard let cursor else { return true }
        return cursor.target == target && cursor.scope == scope
    }

    private static func validName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        return !scalars.isEmpty && scalars.count <= 80 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !scalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .surrogate })
    }

    private static func validDirectoryID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func invalid(_ method: String) -> AxoProtocolValidationError {
        .invalidParameters(method: method)
    }
}
