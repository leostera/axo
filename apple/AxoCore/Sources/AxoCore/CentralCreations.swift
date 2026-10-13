import AxoProtocol
import Foundation
import Observation

/// Volatile capture of normalized creation intent, never a runnable queue or
/// restorable preference. Axod canonicalizes a selected directory before commit.
public struct CentralCreationTicket: Sendable {
  fileprivate let owner: UUID
  public let request: CentralRequest
  public let commandId: UUID
  fileprivate let selection: Selection
  fileprivate let revision: CentralRevision
  fileprivate enum Selection: Sendable {
    case workspace(name: String)
    case session(workspaceId: UUID?, name: String)
  }
}
public enum CentralCreationIssue: Error, Equatable, Sendable {
  case pendingCreation, invalidTicket, alreadySubmitted, invalidOriginal
}
public enum CentralCreation: Equatable, Sendable {
  case workspace(CentralAccepted<CentralWorkspaceGraph>)
  case session(CentralAccepted<CentralSessionGraph>)
  case standalone(CentralAccepted<CentralSessionGraph>)
  public var sessionId: UUID {
    switch self {
    case .workspace(let accepted): accepted.graph.initialSession.session.sessionId
    case .session(let accepted), .standalone(let accepted): accepted.graph.session.sessionId
    }
  }
  public var workspaceId: UUID? {
    switch self {
    case .workspace(let accepted): accepted.graph.workspace.workspaceId
    case .session(let accepted), .standalone(let accepted): accepted.graph.session.workspaceId
    }
  }
  public var revision: CentralRevision {
    switch self {
    case .workspace(let accepted): accepted.revision
    case .session(let accepted), .standalone(let accepted): accepted.revision
    }
  }
}
public enum CentralCreationResolution: Equatable, Sendable {
  case missing
  case accepted(CentralCreation)
}

/// One explicit creation at a time. Transport errors after beginSubmission do
/// not release intent. Only an exact immutable accepted graph clears that fence.
@MainActor @Observable public final class CentralCreations {
  @ObservationIgnored private let owner = UUID()
  private enum Phase: Equatable { case reserved, awaitingOriginal }
  private struct Pending {
    let ticket: CentralCreationTicket
    var phase: Phase
  }
  private var pending: Pending?
  public init() {}
  public var pendingTicket: CentralCreationTicket? { pending?.ticket }
  public var hasPending: Bool { pending != nil }

  public func captureWorkspace(
    source: CentralSource, revision: CentralRevision, name: String, directoryPath: String
  ) throws -> CentralCreationTicket {
    let commandId = UUID()
    let request = try CentralRequest.createWorkspace(
      source: source, commandId: commandId, expectedRevision: revision, name: name,
      directoryPath: directoryPath)
    return try reserve(
      request, commandId: commandId, revision: revision, selection: .workspace(name: name))
  }
  public func captureSession(
    source: CentralSource, revision: CentralRevision, workspaceId: UUID?,
    name: String = "New Session"
  ) throws -> CentralCreationTicket {
    let commandId = UUID()
    let request = try CentralRequest.createSession(
      source: source, workspaceId: workspaceId, commandId: commandId, expectedRevision: revision,
      name: name)
    return try reserve(
      request, commandId: commandId, revision: revision,
      selection: .session(workspaceId: workspaceId, name: name))
  }
  private func reserve(
    _ request: CentralRequest, commandId: UUID, revision: CentralRevision,
    selection: CentralCreationTicket.Selection
  ) throws -> CentralCreationTicket {
    guard pending == nil else { throw CentralCreationIssue.pendingCreation }
    guard request.commandId == commandId else { throw CentralCreationIssue.invalidTicket }
    let frame = RPCRequest(
      id: .string(String(repeating: "0", count: 36)), method: request.method,
      params: request.parameters)
    guard try JSONEncoder().encode(frame).count <= AxoProtocolCodec.maximumFrameBytes else {
      throw CentralCreationIssue.invalidTicket
    }
    let ticket = CentralCreationTicket(
      owner: owner, request: request, commandId: commandId, selection: selection, revision: revision
    )
    pending = Pending(ticket: ticket, phase: .reserved)
    return ticket
  }
  public func beginSubmission(_ ticket: CentralCreationTicket) throws -> CentralRequest {
    try requireTicket(ticket)
    guard pending?.phase == .reserved else { throw CentralCreationIssue.alreadySubmitted }
    pending?.phase = .awaitingOriginal
    return ticket.request
  }
  public func abandonBeforeSubmission(_ ticket: CentralCreationTicket) throws {
    try requireTicket(ticket)
    guard pending?.phase == .reserved else { throw CentralCreationIssue.alreadySubmitted }
    pending = nil
  }
  public func reconciliation(_ ticket: CentralCreationTicket, source: CentralSource) throws
    -> CentralRequest
  {
    try requireAwaiting(ticket)
    guard let captured = ticket.request.source,
      captured.machine.machineId == source.machine.machineId,
      captured.storeGeneration == source.storeGeneration
    else { throw CentralCreationIssue.invalidTicket }
    return try CentralRequest.operation(source: source, commandId: ticket.commandId)
  }
  public func acknowledgeSubmission(_ ticket: CentralCreationTicket, result: JSONValue) throws
    -> CentralCreationResolution
  {
    try requireAwaiting(ticket)
    return try acknowledge(ticket, response: ticket.request.parseResult(result))
  }
  public func acknowledgeReconciliation(
    _ ticket: CentralCreationTicket, source: CentralSource, result: JSONValue
  ) throws -> CentralCreationResolution {
    let request = try reconciliation(ticket, source: source)
    return try acknowledge(ticket, response: request.parseResult(result))
  }
  private func acknowledge(_ ticket: CentralCreationTicket, response: CentralResponse) throws
    -> CentralCreationResolution
  {
    guard case .operation(let original, _) = response.payload else {
      throw CentralCreationIssue.invalidOriginal
    }
    return try acknowledge(ticket, original: original)
  }
  public func acknowledgeSubmission(_ ticket: CentralCreationTicket, response: CentralResponse)
    throws -> CentralCreationResolution
  {
    try requireAwaiting(ticket)
    guard response.source == ticket.request.source else {
      throw CentralCreationIssue.invalidOriginal
    }
    return try acknowledge(ticket, response: response)
  }
  public func acknowledgeReconciliation(
    _ ticket: CentralCreationTicket, source: CentralSource, response: CentralResponse
  ) throws -> CentralCreationResolution {
    let request = try reconciliation(ticket, source: source)
    guard response.source == request.source, case .operation(let original, _) = response.payload
    else { throw CentralCreationIssue.invalidOriginal }
    return try acknowledge(ticket, original: original)
  }
  private func acknowledge(_ ticket: CentralCreationTicket, original: CentralOperation?) throws
    -> CentralCreationResolution
  {
    guard let original else { return .missing }
    guard original.commandId == ticket.commandId,
      original.revision.rawValue == ticket.revision.rawValue + 1
    else { throw CentralCreationIssue.invalidOriginal }
    let creation: CentralCreation
    switch (ticket.selection, original) {
    case (.workspace(let name), .createWorkspace(let accepted)):
      guard name.utf8.elementsEqual(accepted.graph.workspace.name.utf8),
        accepted.graph.workspace.lifecycle == .open,
        accepted.graph.workspace.configRevision == original.revision,
        accepted.graph.initialSession.session.name.utf8.elementsEqual("Session".utf8),
        initialGraph(accepted.graph.initialSession, revision: original.revision)
      else { throw CentralCreationIssue.invalidOriginal }
      creation = .workspace(accepted)
    case (.session(let workspace, let name), .createSession(let accepted)) where workspace != nil:
      guard workspace == accepted.graph.session.workspaceId,
        name.utf8.elementsEqual(accepted.graph.session.name.utf8),
        initialGraph(accepted.graph, revision: original.revision)
      else { throw CentralCreationIssue.invalidOriginal }
      creation = .session(accepted)
    case (.session(nil, let name), .createStandalone(let accepted)):
      guard accepted.graph.session.workspaceId == nil,
        name.utf8.elementsEqual(accepted.graph.session.name.utf8),
        initialGraph(accepted.graph, revision: original.revision)
      else { throw CentralCreationIssue.invalidOriginal }
      creation = .standalone(accepted)
    default: throw CentralCreationIssue.invalidOriginal
    }
    pending = nil
    return .accepted(creation)
  }
  private func initialGraph(_ graph: CentralSessionGraph, revision: CentralRevision) -> Bool {
    guard graph.session.lifecycle == .open, !graph.session.manualName,
      graph.session.configRevision == revision,
      graph.panes.count == 2,
      graph.panes.allSatisfy({ $0.present && $0.configRevision == revision })
    else { return false }
    return graph.panes.contains { $0.role == .pi && $0.ordinal == 0 }
      && graph.panes.contains { $0.role == .accountShell && $0.ordinal == 1 }
  }
  private func requireTicket(_ ticket: CentralCreationTicket) throws {
    guard ticket.owner == owner, pending?.ticket.commandId == ticket.commandId else {
      throw CentralCreationIssue.invalidTicket
    }
  }
  private func requireAwaiting(_ ticket: CentralCreationTicket) throws {
    try requireTicket(ticket)
    guard pending?.phase == .awaitingOriginal else { throw CentralCreationIssue.invalidTicket }
  }
}
