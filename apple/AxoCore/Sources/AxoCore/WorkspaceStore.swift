import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct WorkspaceID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct AxoSessionID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct PaneID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }
public enum PaneKind: String, Codable, Sendable { case pi, shell }

public struct PaneRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: PaneID
    public let kind: PaneKind
    public init(id: PaneID = PaneID(), kind: PaneKind) { self.id = id; self.kind = kind }
}

public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case pane(PaneID)
    case split(axis: SplitAxis, fraction: Double, first: PaneLayout, second: PaneLayout)

    public var panes: [PaneID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return first.panes + second.panes
        }
    }
    public func adding(_ newPane: PaneID, beside target: PaneID, axis: SplitAxis) -> PaneLayout {
        switch self {
        case .pane(let id):
            return id == target ? .split(axis: axis, fraction: 0.5, first: self, second: .pane(newPane)) : self
        case .split(let existingAxis, let fraction, let first, let second):
            return .split(axis: existingAxis, fraction: fraction,
                          first: first.adding(newPane, beside: target, axis: axis),
                          second: second.adding(newPane, beside: target, axis: axis))
        }
    }
    public func removing(_ target: PaneID) -> PaneLayout? {
        switch self {
        case .pane(let id): return id == target ? nil : self
        case .split(let axis, let fraction, let first, let second):
            switch (first.removing(target), second.removing(target)) {
            case (nil, nil): return nil
            case (let survivor?, nil), (nil, let survivor?): return survivor
            case (let first?, let second?): return .split(axis: axis, fraction: fraction, first: first, second: second)
            }
        }
    }
    /// Paths address split nodes in one captured layout, never pane text or selection.
    public func settingFraction(_ fraction: Double, at path: [Bool]) throws -> PaneLayout {
        guard fraction.isFinite, (0.1...0.9).contains(fraction),
              case .split(let axis, let oldFraction, let first, let second) = self else { throw WorkspaceFault.invalidLayout }
        guard let descendSecond = path.first else { return .split(axis: axis, fraction: fraction, first: first, second: second) }
        let remaining = Array(path.dropFirst())
        return .split(axis: axis, fraction: oldFraction,
                      first: descendSecond ? first : try first.settingFraction(fraction, at: remaining),
                      second: descendSecond ? try second.settingFraction(fraction, at: remaining) : second)
    }

    fileprivate func validate(depth: Int = 0) throws {
        guard depth < 32 else { throw WorkspaceFault.invalidLayout }
        if case .split(_, let fraction, let first, let second) = self {
            guard fraction.isFinite, fraction > 0, fraction < 1 else { throw WorkspaceFault.invalidLayout }
            try first.validate(depth: depth + 1)
            try second.validate(depth: depth + 1)
        }
    }
}

public struct WorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: WorkspaceID
    public var name: String
}
public struct WorkSession: Codable, Equatable, Identifiable, Sendable {
    public let id: AxoSessionID
    public var workspaceID: WorkspaceID
    public var name: String
    public let directory: String
    public let piSessionFile: String
    public var conversationID: String?
    public var panes: [PaneRecord]
    public var layout: PaneLayout?
    public var focusedPane: PaneID?
}

public struct WorkspaceRegistry: Codable, Equatable, Sendable {
    public var version = 1
    public var revision = 0
    public var workspaces: [WorkspaceRecord] = []
    public var sessions: [WorkSession] = []
    public var selectedSession: AxoSessionID?
    // Only IDs/arguments, never uncertain prompts. Creation retries are idempotent.
    public var creations: [String: CreationReceipt] = [:]
    public init() {}

    public func validate() throws {
        guard version == 1, revision >= 0, workspaces.count <= 100, sessions.count <= 1_000,
              creations.count <= 2_000 else { throw WorkspaceFault.capacity }
        let workspaceIDs = Set(workspaces.map(\.id))
        let sessionIDs = Set(sessions.map(\.id))
        guard workspaceIDs.count == workspaces.count, sessionIDs.count == sessions.count,
              selectedSession.map(sessionIDs.contains) ?? true else { throw WorkspaceFault.invalidMembership }
        for workspace in workspaces {
            guard try WorkspaceStore.validName(workspace.name) == workspace.name else { throw WorkspaceFault.invalidName }
        }
        var allPanes = Set<PaneID>()
        var conversations = Set<String>()
        for session in sessions {
            guard try WorkspaceStore.validName(session.name) == session.name else { throw WorkspaceFault.invalidName }
            guard workspaceIDs.contains(session.workspaceID), validPath(session.directory),
                  validPath(session.piSessionFile), session.panes.count <= 128,
                  session.panes.filter({ $0.kind == .pi }).count <= 1 else { throw WorkspaceFault.invalidMembership }
            if let conversation = session.conversationID {
                guard !conversation.isEmpty, conversation.utf8.count <= 128,
                      conversations.insert(conversation).inserted else { throw WorkspaceFault.invalidMembership }
            }
            try session.layout?.validate()
            let ids = session.panes.map(\.id)
            let layoutIDs = session.layout?.panes ?? []
            guard Set(ids).count == ids.count, Set(ids) == Set(layoutIDs), ids.count == layoutIDs.count,
                  session.focusedPane.map(Set(ids).contains) ?? true else { throw WorkspaceFault.invalidLayout }
            for id in ids { guard allPanes.insert(id).inserted else { throw WorkspaceFault.invalidLayout } }
        }
    }
    private func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4_096 && !path.contains("\u{0}")
    }
}

public struct CreationReceipt: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String
    public let workspaceID: WorkspaceID
    public let sessionID: AxoSessionID
}
public enum WorkspaceFault: Error, Equatable {
    case invalidName, invalidMembership, invalidLayout, capacity, conflict, notFound, corruptStore
}

/// Single-owner, copy/validate/atomic-commit store. Failed writes leave memory and disk unchanged.
/// No transcript, credentials, process claims, or prompt replay queue belongs in this file.
public final class WorkspaceStore {
    public private(set) var registry: WorkspaceRegistry
    public let url: URL
    private let scratchRoot: URL

    public init(url: URL, scratchRoot: URL) throws {
        self.url = url; self.scratchRoot = scratchRoot
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw WorkspaceFault.corruptStore }
            registry = try JSONDecoder().decode(WorkspaceRegistry.self, from: Data(contentsOf: url))
            try registry.validate()
        } else { registry = WorkspaceRegistry() }
    }

    public static func validName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 120,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw WorkspaceFault.invalidName }
        return name
    }

    @discardableResult
    public func createWorkspace(name: String, commandID: String = UUID().uuidString,
                                initialDirectory: String? = nil, initialSessionFile: String? = nil) throws -> CreationReceipt {
        let name = try Self.validName(name)
        if let receipt = registry.creations[commandID] {
            guard receipt.kind == "workspace", receipt.name == name else { throw WorkspaceFault.conflict }
            return receipt
        }
        let workspaceID = WorkspaceID(), sessionID = AxoSessionID()
        let receipt = CreationReceipt(kind: "workspace", name: name, workspaceID: workspaceID, sessionID: sessionID)
        try commit { state in
            state.workspaces.append(WorkspaceRecord(id: workspaceID, name: name))
            state.sessions.append(newSession(id: sessionID, workspaceID: workspaceID, name: "New session",
                                             directory: initialDirectory, sessionFile: initialSessionFile))
            state.selectedSession = sessionID
            state.creations[commandID] = receipt
        }
        return receipt
    }

    @discardableResult
    public func createSession(workspaceID: WorkspaceID, name: String, commandID: String = UUID().uuidString) throws -> CreationReceipt {
        let name = try Self.validName(name)
        if let receipt = registry.creations[commandID] {
            guard receipt.kind == "session", receipt.name == name, receipt.workspaceID == workspaceID else { throw WorkspaceFault.conflict }
            return receipt
        }
        guard registry.workspaces.contains(where: { $0.id == workspaceID }) else { throw WorkspaceFault.notFound }
        let sessionID = AxoSessionID()
        let receipt = CreationReceipt(kind: "session", name: name, workspaceID: workspaceID, sessionID: sessionID)
        try commit { state in
            state.sessions.append(newSession(id: sessionID, workspaceID: workspaceID, name: name))
            state.selectedSession = sessionID
            state.creations[commandID] = receipt
        }
        return receipt
    }

    public func select(_ id: AxoSessionID) throws {
        guard registry.sessions.contains(where: { $0.id == id }) else { throw WorkspaceFault.notFound }
        try commit { $0.selectedSession = id }
    }
    public func updateSession(_ id: AxoSessionID, _ change: (inout WorkSession) throws -> Void) throws {
        try commit { state in
            guard let index = state.sessions.firstIndex(where: { $0.id == id }) else { throw WorkspaceFault.notFound }
            try change(&state.sessions[index])
        }
    }
    @discardableResult
    public func addShell(sessionID: AxoSessionID, beside paneID: PaneID, axis: SplitAxis) throws -> PaneID {
        let pane = PaneRecord(kind: .shell)
        try updateSession(sessionID) { session in
            guard let layout = session.layout, layout.panes.contains(paneID) else { throw WorkspaceFault.notFound }
            session.panes.append(pane)
            session.layout = layout.adding(pane.id, beside: paneID, axis: axis)
            session.focusedPane = pane.id
        }
        return pane.id
    }
    public func closePane(sessionID: AxoSessionID, paneID: PaneID) throws {
        try updateSession(sessionID) { session in
            guard session.panes.contains(where: { $0.id == paneID }) else { throw WorkspaceFault.notFound }
            session.panes.removeAll { $0.id == paneID }
            session.layout = session.layout?.removing(paneID)
            if session.focusedPane == paneID { session.focusedPane = session.layout?.panes.first }
        }
    }

    private func newSession(id: AxoSessionID, workspaceID: WorkspaceID, name: String,
                            directory: String? = nil, sessionFile: String? = nil) -> WorkSession {
        let root = scratchRoot.appendingPathComponent(workspaceID.rawValue.uuidString)
            .appendingPathComponent(id.rawValue.uuidString)
        let pane = PaneRecord(kind: .pi)
        return WorkSession(id: id, workspaceID: workspaceID, name: name,
                           directory: directory ?? root.path,
                           piSessionFile: sessionFile ?? root.appendingPathComponent("session.jsonl").path,
                           panes: [pane], layout: .pane(pane.id), focusedPane: pane.id)
    }
    private func commit(_ change: (inout WorkspaceRegistry) throws -> Void) throws {
        var next = registry
        try change(&next)
        next.revision += 1
        try next.validate()
        let data = try JSONEncoder().encode(next)
        guard data.count <= 4 * 1024 * 1024 else { throw WorkspaceFault.capacity }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".registry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Create privately before writing any paths/metadata, then rename as the commit point.
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceFault.corruptStore
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        registry = next
    }
}
