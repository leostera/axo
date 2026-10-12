import AxoProtocol
import Foundation

/// A complete, revision-consistent central catalog. No partial page or cached
/// legacy record can be published as an authoritative empty catalog.
public struct CentralCatalog: Equatable, Sendable {
    public let source: CentralSource
    public let revision: CentralRevision
    public let workspaces: [CentralWorkspace]
    public let sessions: [CentralSessionView]
    public let sessionsByWorkspace: [UUID?: [CentralSessionView]]
    public let terminals: [TerminalSnapshot]

    /// Aggregate already-parsed records into a complete graph. Cross-scope
    /// identity/ancestry and source fences cannot be bypassed by other clients.
    public init(source: CentralSource, revision: CentralRevision, workspaces: [CentralWorkspace], sessions: [CentralSessionView]) throws {
        let workspaceIDs = Set(workspaces.map(\.workspaceId))
        let panes = sessions.flatMap(\.panes), terminals = sessions.flatMap(\.terminals)
        guard workspaces.count <= 128, workspaceIDs.count == workspaces.count,
              sessions.count <= 1000, Set(sessions.map { $0.session.sessionId }).count == sessions.count,
              sessions.allSatisfy({ $0.session.workspaceId.map(workspaceIDs.contains) ?? true }),
              workspaces.allSatisfy({ $0.configRevision <= revision }),
              sessions.allSatisfy({ $0.session.configRevision <= revision }),
              panes.allSatisfy({ $0.desired.configRevision <= revision }),
              Set(panes.map { $0.desired.paneId }).count == panes.count,
              terminals.count <= 128, Set(terminals.map { $0.runtime.runtimeGeneration }).count == terminals.count,
              terminals.allSatisfy({ $0.runtime.hostGeneration == source.machine.hostGeneration }) else {
            throw AxoProtocolValidationError.invalidResult(method: "axo.state.session.list")
        }
        self.source = source; self.revision = revision
        self.workspaces = workspaces; self.sessions = sessions; self.terminals = terminals
        sessionsByWorkspace = Dictionary(grouping: sessions) { $0.session.workspaceId }
    }
}
