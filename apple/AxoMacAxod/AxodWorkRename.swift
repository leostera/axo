import AxoCore
import AxoProtocol
import Foundation

/// A row editor cannot borrow a later selection or catalog revision.
@MainActor
struct AxodWorkRename {
    enum Destination {
        case workspace(WorkWorkspaceTarget)
        case session(WorkSessionTarget)
    }
    enum Result {
        case workspace(WorkWorkspaceRecord)
        case session(WorkSessionRecord)
    }
    let id = UUID()
    let source: MachineTarget
    let operation: UUID
    let revision: WorkRevision
    let destination: Destination

    func dispatch(name: String, command: UUID, connection: AxoJSONRPCWebSocketConnection,
                  beforeDispatch: () throws -> Void) async throws -> Result {
        switch destination {
        case .workspace(let target):
            let parameters = WorkspaceRenameParameters(target: target, commandId: command, expectedRevision: revision, name: name)
            try AxoProtocolWorkRequestValidator.validate(parameters)
            try beforeDispatch()
            let value = try await connection.request(method: AxoProtocol.Method.renameWorkspace, parameters: parameters)
            let result = try AxoProtocolResultValidator.workspaceRename(value, target: target, expectedRevision: revision, name: name)
            return .workspace(result.workspace)
        case .session(let target):
            let parameters = SessionRenameParameters(target: target, commandId: command, expectedRevision: revision, name: name)
            try AxoProtocolWorkRequestValidator.validate(parameters)
            try beforeDispatch()
            let value = try await connection.request(method: AxoProtocol.Method.renameSession, parameters: parameters)
            let result = try AxoProtocolResultValidator.sessionRename(value, target: target, expectedRevision: revision, name: name)
            guard result.session.manualName == true else { throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.renameSession) }
            return .session(result.session)
        }
    }
}
