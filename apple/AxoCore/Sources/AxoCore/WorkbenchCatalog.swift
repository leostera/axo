import Foundation

public enum CatalogFault: Error, Equatable {
    case duplicateWorkspace
    case duplicateSession
    case capacity
    case invalidMembership
    case invalidRevision
}

/// The complete, transcript-free catalog stored for immediate offline navigation.
public struct WorkbenchCatalogSnapshot: Codable, Equatable, Sendable {
    public let revision: Int
    public let workspaces: [CatalogWorkspace]
    public let sessions: [CatalogSession]

    public init(revision: Int, workspaces: [CatalogWorkspace], sessions: [CatalogSession]) {
        self.revision = revision
        self.workspaces = workspaces
        self.sessions = sessions
    }
}

/// An atomic, bounded on-device cache of workspace/session metadata only.
public struct WorkbenchCatalogCache {
    public static let maximumBytes = 512 * 1024
    private static let formatVersion = 1

    private struct Envelope: Codable {
        let formatVersion: Int
        let catalog: WorkbenchCatalogSnapshot
    }

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = support.appendingPathComponent("Axo", isDirectory: true)
                .appendingPathComponent("phone-workbench-catalog.json")
        }
    }

    public func load() throws -> WorkbenchCatalog? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumBytes else { throw CatalogCacheFault.tooLarge }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.formatVersion == Self.formatVersion else { throw CatalogCacheFault.unsupportedVersion }
        return try WorkbenchCatalog(snapshot: envelope.catalog)
    }

    public func save(_ catalog: WorkbenchCatalog) throws {
        guard let snapshot = catalog.snapshot() else { return }
        _ = try WorkbenchCatalog(snapshot: snapshot)
        let data = try JSONEncoder().encode(Envelope(formatVersion: Self.formatVersion, catalog: snapshot))
        guard data.count <= Self.maximumBytes else { throw CatalogCacheFault.tooLarge }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}

public enum CatalogCacheFault: Error, Equatable {
    case tooLarge
    case unsupportedVersion
}

/// A bounded, revision-consistent catalog assembled from relay pages.
public struct WorkbenchCatalog: Equatable, Sendable {
    public private(set) var revision: Int?
    public private(set) var workspaces: [CatalogWorkspace] = []
    public private(set) var sessions: [CatalogSession] = []
    public private(set) var nextCursor: String?
    public private(set) var hostOnline = false

    public init() {}

    public init(snapshot: WorkbenchCatalogSnapshot) throws {
        guard snapshot.revision >= 0 else { throw CatalogFault.invalidRevision }
        guard snapshot.workspaces.count <= 100, snapshot.sessions.count <= 1_000 else {
            throw CatalogFault.capacity
        }
        let workspaceIDs = Set(snapshot.workspaces.map(\.id))
        let sessionIDs = Set(snapshot.sessions.map(\.id))
        guard workspaceIDs.count == snapshot.workspaces.count else { throw CatalogFault.duplicateWorkspace }
        guard sessionIDs.count == snapshot.sessions.count else { throw CatalogFault.duplicateSession }
        guard snapshot.workspaces.allSatisfy({ (try? WorkspaceStore.validName($0.name)) == $0.name }),
              snapshot.sessions.allSatisfy({ (try? WorkspaceStore.validName($0.name)) == $0.name }),
              snapshot.sessions.allSatisfy({ workspaceIDs.contains($0.workspaceId) }) else {
            throw CatalogFault.invalidMembership
        }

        revision = snapshot.revision
        workspaces = snapshot.workspaces
        sessions = snapshot.sessions
        nextCursor = nil
        hostOnline = false
    }

    public func snapshot() -> WorkbenchCatalogSnapshot? {
        guard let revision, nextCursor == nil else { return nil }
        return WorkbenchCatalogSnapshot(revision: revision, workspaces: workspaces, sessions: sessions)
    }

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
