import AxoProtocol
import Foundation

enum CentralCatalogLoader {
    /// Every workspace scope (plus explicit home scope) is loaded at one captured
    /// revision. Bounds and cross-page uniqueness are checked before publication.
    static func load(source: CentralSource, send: @Sendable (CentralRequest) async throws -> CentralResponse) async throws -> CentralCatalog {
        let bootstrap = try CentralRequest.bootstrap(machine: source.machine)
        let first = try await send(bootstrap)
        try sameSource(first, source)
        guard first.payload == .bootstrap else { throw invalid() }
        let revision = first.revision
        var workspaces: [CentralWorkspace] = [], cursor: CentralCursor?
        repeat {
            let response = try await send(CentralRequest.workspaces(source: source, cursor: cursor))
            try sameRevision(response, source, revision)
            guard case .workspaces(let records, let next) = response.payload else { throw invalid() }
            workspaces.append(contentsOf: records)
            guard workspaces.count <= 128, Set(workspaces.map(\.workspaceId)).count == workspaces.count else { throw invalid() }
            cursor = next
        } while cursor != nil
        var sessions: [CentralSessionView] = []
        let scopes: [UUID?] = [nil] + workspaces.map { Optional($0.workspaceId) }
        for workspace in scopes {
            cursor = nil
            repeat {
                let response = try await send(CentralRequest.sessions(source: source, workspaceId: workspace, cursor: cursor))
                try sameRevision(response, source, revision)
                guard case .sessions(let records, let next) = response.payload,
                      records.allSatisfy({ $0.session.workspaceId == workspace }) else { throw invalid() }
                sessions.append(contentsOf: records)
                guard sessions.count <= 1000, Set(sessions.map { $0.session.sessionId }).count == sessions.count else { throw invalid() }
                cursor = next
            } while cursor != nil
        }
        let last = try await send(bootstrap)
        try sameRevision(last, source, revision)
        guard last.payload == .bootstrap else { throw invalid() }
        return try CentralCatalog(source: source, revision: revision, workspaces: workspaces, sessions: sessions)
    }
    private static func sameSource(_ response: CentralResponse, _ expected: CentralSource) throws {
        guard response.source.machine == expected.machine else { throw AxoControlPlaneSessionError.superseded }
        guard response.source.storeGeneration == expected.storeGeneration else {
            throw AxoProtocolValidationError.staleStore(expected: expected.storeGeneration, actual: response.source.storeGeneration)
        }
    }
    private static func sameRevision(_ response: CentralResponse, _ source: CentralSource, _ revision: CentralRevision) throws {
        try sameSource(response, source)
        guard response.revision == revision else { throw invalid() }
    }
    private static func invalid() -> AxoProtocolValidationError { .invalidResult(method: "axo.state.session.list") }
}
