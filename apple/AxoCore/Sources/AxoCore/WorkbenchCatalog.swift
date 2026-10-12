import Foundation

public enum CatalogFault: Error, Equatable {
    case duplicateWorkspace
    case duplicateSession
    case capacity
    case invalidMembership
}

/// A bounded, revision-consistent catalog assembled from relay pages.
public struct WorkbenchCatalog: Equatable, Sendable {
    public private(set) var revision: Int?
    public private(set) var workspaces: [CatalogWorkspace] = []
    public private(set) var sessions: [CatalogSession] = []
    public private(set) var nextCursor: String?
    public private(set) var hostOnline = false

    public init() {}

    @discardableResult
    public mutating func apply(_ page: CatalogPage) throws -> Bool {
        let startsNewRevision = revision != page.revision
        var nextWorkspaces = startsNewRevision ? [] : workspaces
        var nextSessions = startsNewRevision ? [] : sessions
        var workspaceIDs = Set(nextWorkspaces.map(\.id))
        var sessionIDs = Set(nextSessions.map(\.id))

        for item in page.items {
            switch item {
            case .workspace(let workspace):
                if let existing = nextWorkspaces.first(where: { $0.id == workspace.id }) {
                    guard existing == workspace else { throw CatalogFault.duplicateWorkspace }
                    continue
                }
                workspaceIDs.insert(workspace.id)
                nextWorkspaces.append(workspace)
            case .session(let session):
                if let existing = nextSessions.first(where: { $0.id == session.id }) {
                    guard existing == session else { throw CatalogFault.duplicateSession }
                    continue
                }
                sessionIDs.insert(session.id)
                nextSessions.append(session)
            }
        }

        guard nextWorkspaces.count <= 100, nextSessions.count <= 1_000 else { throw CatalogFault.capacity }
        if page.nextCursor == nil {
            let knownWorkspaceIDs = Set(nextWorkspaces.map(\.id))
            guard nextSessions.allSatisfy({ knownWorkspaceIDs.contains($0.workspaceId) }) else {
                throw CatalogFault.invalidMembership
            }
        }

        revision = page.revision
        workspaces = nextWorkspaces
        sessions = nextSessions
        nextCursor = page.nextCursor
        hostOnline = page.hostOnline
        return startsNewRevision
    }

    public mutating func updateHostOnline(_ isOnline: Bool) {
        hostOnline = isOnline
    }

    public func workspace(id: WorkspaceID) -> CatalogWorkspace? {
        workspaces.first { $0.id == id }
    }

    public func session(id: AxoSessionID) -> CatalogSession? {
        sessions.first { $0.id == id }
    }

    public func sessions(in workspaceID: WorkspaceID) -> [CatalogSession] {
        sessions.filter { $0.workspaceId == workspaceID }
    }

    public func searchNames(_ query: String) -> [CatalogPage.Item] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return workspaces.compactMap { workspace in
            workspace.name.localizedCaseInsensitiveContains(term) ? .workspace(workspace) : nil
        } + sessions.compactMap { session in
            session.name.localizedCaseInsensitiveContains(term) ? .session(session) : nil
        }
    }
}
