import AxoProtocol
import Foundation
import Observation

public enum CentralRenameTarget: Equatable, Sendable {
    case workspace(UUID)
    case session(workspaceId: UUID?, sessionId: UUID)
}

public struct CentralRenameCapture: Equatable, Sendable {
    fileprivate let owner: UUID
    public let source: CentralSource
    public let revision: CentralRevision
    public let target: CentralRenameTarget
    public let originalName: String
}

public struct CentralRenameTicket: Sendable {
    fileprivate let owner: UUID
    public let request: CentralRequest
    public let commandId: UUID
    fileprivate let target: CentralRenameTarget
    fileprivate let name: String
    fileprivate let expectedRevision: CentralRevision
}

public enum CentralRenameIssue: Error, Equatable, Sendable {
    case pendingRename, invalidTicket, alreadySubmitted, invalidOriginal
}

public enum CentralRenameResolution: Equatable, Sendable {
    case missing
    case renamed(CentralOperation)
}

/// One revision-captured Rename. Submitted originals remain fenced until the
/// exact target/name is observed; lookup is read-only and never permits replay.
@MainActor @Observable public final class CentralRenames {
    @ObservationIgnored private let owner = UUID()
    private enum Phase: Equatable { case reserved, awaitingOriginal }
    private struct Pending {
        let ticket: CentralRenameTicket
        var phase: Phase
    }
    private var pending: Pending?
    private var prepared: CentralRenameCapture?

    public init() {}
    public var pendingTicket: CentralRenameTicket? { pending?.ticket }

    public func prepareWorkspace(
        source: CentralSource, revision: CentralRevision, workspaceId: UUID, currentName: String
    ) throws -> CentralRenameCapture {
        try prepare(source: source, revision: revision, target: .workspace(workspaceId), currentName: currentName)
    }

    public func prepareSession(
        source: CentralSource, revision: CentralRevision, workspaceId: UUID?, sessionId: UUID,
        currentName: String
    ) throws -> CentralRenameCapture {
        try prepare(source: source, revision: revision,
                    target: .session(workspaceId: workspaceId, sessionId: sessionId), currentName: currentName)
    }

    private func prepare(
        source: CentralSource, revision: CentralRevision, target: CentralRenameTarget, currentName: String
    ) throws -> CentralRenameCapture {
        guard pending == nil, prepared == nil else { throw CentralRenameIssue.pendingRename }
        let capture = CentralRenameCapture(owner: owner, source: source, revision: revision,
                                           target: target, originalName: currentName)
        prepared = capture
        return capture
    }

    public func abandon(_ capture: CentralRenameCapture) throws {
        guard capture.owner == owner, prepared == capture else { throw CentralRenameIssue.invalidTicket }
        prepared = nil
    }

    public func capture(_ origin: CentralRenameCapture, name: String) throws -> CentralRenameTicket {
        guard origin.owner == owner, prepared == origin, pending == nil else {
            throw CentralRenameIssue.invalidTicket
        }
        prepared = nil
        switch origin.target {
        case .workspace(let id):
            return try captureWorkspace(source: origin.source, revision: origin.revision,
                                        workspaceId: id, name: name)
        case .session(let workspace, let id):
            return try captureSession(source: origin.source, revision: origin.revision,
                                      workspaceId: workspace, sessionId: id, name: name)
        }
    }
    public var hasPending: Bool { pending != nil }

    public func captureWorkspace(
        source: CentralSource, revision: CentralRevision, workspaceId: UUID, name: String
    ) throws -> CentralRenameTicket {
        let commandId = UUID()
        let request = try CentralRequest.renameWorkspace(
            source: source, workspaceId: workspaceId, commandId: commandId,
            expectedRevision: revision, name: name)
        return try reserve(request, commandId: commandId, revision: revision,
                           target: .workspace(workspaceId), name: name)
    }

    public func captureSession(
        source: CentralSource, revision: CentralRevision, workspaceId: UUID?, sessionId: UUID,
        name: String
    ) throws -> CentralRenameTicket {
        let commandId = UUID()
        let request = try CentralRequest.renameSession(
            source: source, workspaceId: workspaceId, sessionId: sessionId,
            commandId: commandId, expectedRevision: revision, name: name)
        return try reserve(request, commandId: commandId, revision: revision,
                           target: .session(workspaceId: workspaceId, sessionId: sessionId), name: name)
    }

    private func reserve(
        _ request: CentralRequest, commandId: UUID, revision: CentralRevision,
        target: CentralRenameTarget, name: String
    ) throws -> CentralRenameTicket {
        guard pending == nil, prepared == nil else { throw CentralRenameIssue.pendingRename }
        guard request.commandId == commandId, revision.rawValue < 9_007_199_254_740_991 else {
            throw CentralRenameIssue.invalidTicket
        }
        let frame = RPCRequest(id: .string(String(repeating: "0", count: 36)),
                               method: request.method, params: request.parameters)
        guard try JSONEncoder().encode(frame).count <= AxoProtocolCodec.maximumFrameBytes else {
            throw CentralRenameIssue.invalidTicket
        }
        let ticket = CentralRenameTicket(owner: owner, request: request, commandId: commandId,
                                         target: target, name: name, expectedRevision: revision)
        pending = Pending(ticket: ticket, phase: .reserved)
        return ticket
    }

    public func beginSubmission(_ ticket: CentralRenameTicket) throws -> CentralRequest {
        try require(ticket)
        guard pending?.phase == .reserved else { throw CentralRenameIssue.alreadySubmitted }
        pending?.phase = .awaitingOriginal
        return ticket.request
    }

    public func abandonBeforeSubmission(_ ticket: CentralRenameTicket) throws {
        try require(ticket)
        guard pending?.phase == .reserved else { throw CentralRenameIssue.alreadySubmitted }
        pending = nil
    }

    public func reconciliation(_ ticket: CentralRenameTicket, source: CentralSource) throws -> CentralRequest {
        try requireAwaiting(ticket)
        guard let captured = ticket.request.source,
              captured.machine.machineId == source.machine.machineId,
              captured.storeGeneration == source.storeGeneration else {
            throw CentralRenameIssue.invalidTicket
        }
        return try CentralRequest.operation(source: source, commandId: ticket.commandId)
    }

    @discardableResult public func acknowledgeSubmission(
        _ ticket: CentralRenameTicket, result: JSONValue
    ) throws -> CentralRenameResolution {
        try requireAwaiting(ticket)
        return try acknowledge(ticket, response: ticket.request.parseResult(result))
    }

    @discardableResult public func acknowledgeSubmission(
        _ ticket: CentralRenameTicket, response: CentralResponse
    ) throws -> CentralRenameResolution {
        try requireAwaiting(ticket)
        guard response.source == ticket.request.source else { throw CentralRenameIssue.invalidOriginal }
        return try acknowledge(ticket, response: response)
    }

    @discardableResult public func acknowledgeReconciliation(
        _ ticket: CentralRenameTicket, source: CentralSource, result: JSONValue
    ) throws -> CentralRenameResolution {
        let request = try reconciliation(ticket, source: source)
        return try acknowledge(ticket, response: request.parseResult(result))
    }

    @discardableResult public func acknowledgeReconciliation(
        _ ticket: CentralRenameTicket, source: CentralSource, response: CentralResponse
    ) throws -> CentralRenameResolution {
        let request = try reconciliation(ticket, source: source)
        guard response.source == request.source else { throw CentralRenameIssue.invalidOriginal }
        return try acknowledge(ticket, response: response)
    }

    private func acknowledge(
        _ ticket: CentralRenameTicket, response: CentralResponse
    ) throws -> CentralRenameResolution {
        guard case .operation(let original, _) = response.payload else {
            throw CentralRenameIssue.invalidOriginal
        }
        return try acknowledge(ticket, original: original)
    }

    private func acknowledge(
        _ ticket: CentralRenameTicket, original: CentralOperation?
    ) throws -> CentralRenameResolution {
        guard let original else { return .missing }
        guard original.commandId == ticket.commandId,
              original.revision.rawValue == ticket.expectedRevision.rawValue + 1 else {
            throw CentralRenameIssue.invalidOriginal
        }
        switch (ticket.target, original) {
        case (.workspace(let id), .renameWorkspace(let accepted)):
            guard accepted.graph.workspaceId == id, accepted.graph.name.utf8.elementsEqual(ticket.name.utf8),
                  accepted.graph.configRevision == original.revision else {
                throw CentralRenameIssue.invalidOriginal
            }
        case (.session(let workspaceId, let sessionId), .renameSession(let accepted)):
            guard accepted.graph.workspaceId == workspaceId, accepted.graph.sessionId == sessionId,
                  accepted.graph.name.utf8.elementsEqual(ticket.name.utf8), accepted.graph.manualName,
                  accepted.graph.configRevision == original.revision else {
                throw CentralRenameIssue.invalidOriginal
            }
        default: throw CentralRenameIssue.invalidOriginal
        }
        pending = nil
        return .renamed(original)
    }

    private func require(_ ticket: CentralRenameTicket) throws {
        guard ticket.owner == owner, pending?.ticket.commandId == ticket.commandId else {
            throw CentralRenameIssue.invalidTicket
        }
    }

    private func requireAwaiting(_ ticket: CentralRenameTicket) throws {
        try require(ticket)
        guard pending?.phase == .awaitingOriginal else { throw CentralRenameIssue.invalidTicket }
    }
}
