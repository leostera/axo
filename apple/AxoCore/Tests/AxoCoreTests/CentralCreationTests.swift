import AxoProtocol
import Foundation
import XCTest

@testable import AxoCore

@MainActor final class CentralCreationTests: XCTestCase {
  private let machineID = UUID(), hostID = UUID(), storeID = UUID()
  private func source() throws -> CentralSource {
    try CentralSource(
      machine: .init(machineId: machineID, hostGeneration: hostID), storeGeneration: storeID)
  }
  private func json(_ value: Any) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
  }
  private func original(
    _ ticket: CentralCreationTicket, source: CentralSource, kind: String = "createWorkspace",
    revision: Int? = nil
  ) throws -> JSONValue {
    let acceptedRevision = revision ?? 1
    let workspace = UUID()
    let session = UUID()
    let pi = UUID()
    let shell = UUID()
    let sessionRecord: [String: Any] = [
      "sessionId": session.uuidString,
      "workspaceId": kind == "createStandalone" ? NSNull() : workspace.uuidString,
      "name": kind == "createWorkspace" ? "Session" : "New Session", "manualName": false,
      "lifecycle": "open", "configRevision": acceptedRevision,
    ]
    let panes: [[String: Any]] = [
      [
        "paneId": pi.uuidString, "sessionId": session.uuidString, "role": ["kind": "pi"],
        "present": true, "ordinal": 0, "configRevision": acceptedRevision,
      ],
      [
        "paneId": shell.uuidString, "sessionId": session.uuidString,
        "role": ["kind": "accountShell"], "present": true, "ordinal": 1,
        "configRevision": acceptedRevision,
      ],
    ]
    let graph: [String: Any]
    if kind == "createWorkspace" {
      graph = [
        "workspace": [
          "workspaceId": workspace.uuidString, "name": "Project", "directory": "/canonical/project",
          "lifecycle": "open", "configRevision": acceptedRevision,
        ],
        "initialSession": ["session": sessionRecord, "panes": panes],
      ]
    } else {
      graph = ["session": sessionRecord, "panes": panes]
    }
    let operation: [String: Any] = [
      "kind": kind,
      "accepted": [
        "commandId": ticket.commandId.uuidString, "revision": acceptedRevision, "graph": graph,
      ],
    ]
    return try json([
      "hostGeneration": source.machine.hostGeneration.uuidString,
      "storeGeneration": source.storeGeneration.uuidString,
      "revision": acceptedRevision, "value": ["operation": operation, "session": NSNull(), "deletion": NSNull()],
    ])
  }
  private func missing(_ source: CentralSource, revision: Int = 0) throws -> JSONValue {
    try json([
      "hostGeneration": source.machine.hostGeneration.uuidString,
      "storeGeneration": source.storeGeneration.uuidString,
      "revision": revision, "value": ["operation": NSNull(), "session": NSNull(), "deletion": NSNull()],
    ])
  }
  func testWorkspaceIsSubmittedOnceAndReadOnlyReconciliationAcceptsCanonicalGraph() async throws {
    let source = try source()
    let manager = CentralCreations()
    let revision = CentralRevision(rawValue: 0)!
    let ticket = try manager.captureWorkspace(
      source: source, revision: revision, name: "Project", directoryPath: "/selected/project")
    XCTAssertEqual(ticket.request.method, "axo.state.workspace.create")
    XCTAssertEqual(try manager.beginSubmission(ticket).commandId, ticket.request.commandId)
    XCTAssertThrowsError(try manager.beginSubmission(ticket))
    XCTAssertThrowsError(
      try manager.captureSession(source: source, revision: revision, workspaceId: nil))
    let nextOwner = try CentralSource(
      machine: .init(machineId: machineID, hostGeneration: UUID()), storeGeneration: storeID)
    let lookup = try manager.reconciliation(ticket, source: nextOwner)
    XCTAssertEqual(lookup.method, "axo.state.operation.get")
    XCTAssertNil(lookup.commandId, "An observation is not a new mutation")
    let result = try manager.acknowledgeReconciliation(
      ticket, source: nextOwner, result: original(ticket, source: nextOwner))
    guard case .accepted(.workspace(let accepted)) = result else {
      return XCTFail("Exact complete graph")
    }
    XCTAssertEqual(accepted.graph.initialSession.panes.count, 2)
    XCTAssertFalse(manager.hasPending)
    XCTAssertThrowsError(try manager.reconciliation(ticket, source: nextOwner))
  }
  func testMissingAndMalformedOriginalsNeverReleaseCreationFence() async throws {
    let source = try source()
    let manager = CentralCreations()
    let revision = CentralRevision(rawValue: 0)!
    let ticket = try manager.captureWorkspace(
      source: source, revision: revision, name: "Project", directoryPath: "/selected/project")
    _ = try manager.beginSubmission(ticket)
    XCTAssertEqual(
      try manager.acknowledgeReconciliation(ticket, source: source, result: missing(source)),
      .missing)
    XCTAssertTrue(manager.hasPending)
    let malformed = try original(ticket, source: source, revision: 2)
    XCTAssertThrowsError(try manager.acknowledgeSubmission(ticket, result: malformed))
    XCTAssertTrue(manager.hasPending)
    let foreignStore = try CentralSource(machine: source.machine, storeGeneration: UUID())
    XCTAssertThrowsError(try manager.reconciliation(ticket, source: foreignStore))
    XCTAssertThrowsError(
      try manager.acknowledgeReconciliation(
        ticket, source: foreignStore, result: missing(foreignStore)))
  }
  func testOnlyUnsubmittedCaptureCanBeAbandonedAndStandaloneUsesHomeGraph() async throws {
    let source = try source()
    let manager = CentralCreations()
    let revision = CentralRevision(rawValue: 0)!
    let abandoned = try manager.captureSession(source: source, revision: revision, workspaceId: nil)
    try manager.abandonBeforeSubmission(abandoned)
    XCTAssertFalse(manager.hasPending)
    let standalone = try manager.captureSession(
      source: source, revision: revision, workspaceId: nil)
    _ = try manager.beginSubmission(standalone)
    XCTAssertThrowsError(try manager.abandonBeforeSubmission(standalone))
    guard
      case .accepted(.standalone(let accepted)) = try manager.acknowledgeSubmission(
        standalone, result: original(standalone, source: source, kind: "createStandalone"))
    else {
      return XCTFail("Standalone complete graph")
    }
    XCTAssertNil(accepted.graph.session.workspaceId)
    XCTAssertFalse(manager.hasPending)
  }
}
