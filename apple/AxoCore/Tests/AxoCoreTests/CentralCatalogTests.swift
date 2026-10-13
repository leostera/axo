import AxoProtocol
import Foundation
import XCTest
@testable import AxoCore

private actor CentralReplies {
    enum Mode: Sendable { case normal, duplicateSession, capacity, lateRevision, lateStore }
    let source: CentralSource
    let mode: Mode
    private(set) var requests: [CentralRequest] = []
    private var bootstraps = 0
    init(source: CentralSource, mode: Mode = .normal) { self.source = source; self.mode = mode }
    private func id(_ index: Int) -> String { String(format: "00000000-0000-4000-8000-%012x", index) }
    private func view(workspace: Any, index: Int) -> [String: Any] {
        let session = id(index)
        func pane(_ ordinal: Int) -> [String: Any] {
            ["desired": ["paneId": id(0x100000 + index * 2 + ordinal), "sessionId": session,
                         "role": ["kind": ordinal == 0 ? "pi" : "accountShell"], "present": true, "ordinal": ordinal, "configRevision": 7],
             "availability": "blocked", "lastRuntime": NSNull(), "terminal": NSNull()]
        }
        return ["session": ["sessionId": session, "workspaceId": workspace, "name": "Session", "manualName": false, "lifecycle": "open", "configRevision": 7],
                "panes": [pane(0), pane(1)], "readiness": "blocked"]
    }
    func reply(_ request: CentralRequest) throws -> CentralResponse {
        requests.append(request)
        let parameters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.parameters)) as! [String: Any]
        var revision = 7, generation = source.storeGeneration.uuidString
        let body: [String: Any]
        switch request.method {
        case "axo.state.get":
            bootstraps += 1
            if bootstraps == 2, mode == .lateRevision { revision = 8 }
            if bootstraps == 2, mode == .lateStore { generation = UUID().uuidString }
            body = ["backendCompleteCreation": true, "schemaVersion": 4]
        case "axo.state.workspace.list":
            let count = mode == .capacity ? 129 : 3
            let after = (parameters["cursor"] as? [String: Any])?["after"] as? String
            let candidates = (0..<count).filter { after == nil || id(0x1000 + $0) > after!.lowercased() }
            let selected = Array(candidates.prefix(8))
            let records: [[String: Any]] = selected.map { ["workspaceId": id(0x1000 + $0), "name": "Workspace \($0)", "directory": "/fixture/\($0)", "lifecycle": "open", "configRevision": 7] }
            let next: Any = candidates.count > selected.count ? ["target": parameters["target"]!, "revision": 7, "domain": ["kind": "workspaces"], "after": id(0x1000 + selected.last!)] as [String: Any] : NSNull()
            body = ["records": records, "cursor": next]
        case "axo.state.session.list":
            let workspace = parameters["workspaceId"]!
            let index = workspace as? String
            let scope = index.flatMap { Int($0.suffix(12), radix: 16) }.map { $0 - 0x1000 + 1 } ?? 0
            let count = scope == 0 ? 1 : 4
            let records = (0..<count).map { view(workspace: workspace, index: mode == .duplicateSession ? 0x2000 + $0 : 0x2000 + scope * 16 + $0) }
            body = ["records": records, "cursor": NSNull()]
        default: throw AxoControlPlaneSessionError.unsupportedMethod(request.method)
        }
        let envelope: [String: Any] = ["hostGeneration": source.machine.hostGeneration.uuidString, "storeGeneration": generation, "revision": revision, "value": body]
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: envelope))
        return try request.parseResult(json)
    }
}

final class CentralCatalogTests: XCTestCase {
    private func source() throws -> CentralSource { try CentralSource(machine: .init(machineId: UUID(), hostGeneration: UUID()), storeGeneration: UUID()) }
    func testCompleteCatalogLoadsEveryWorkspacePlusHomeUsingOnlyReadRequests() async throws {
        let source = try source(), fixture = CentralReplies(source: source)
        let catalog = try await CentralCatalogLoader.load(source: source) { try await fixture.reply($0) }
        XCTAssertEqual(catalog.source, source)
        XCTAssertEqual(catalog.workspaces.count, 3)
        XCTAssertEqual(catalog.sessions.count, 13)
        XCTAssertEqual(catalog.sessions.filter { $0.session.workspaceId == nil }.count, 1)
        for workspace in catalog.workspaces { XCTAssertEqual(catalog.sessions.filter { $0.session.workspaceId == workspace.workspaceId }.count, 4) }
        XCTAssertEqual(catalog.revision.rawValue, 7)
        XCTAssertTrue(catalog.terminals.isEmpty)
        XCTAssertThrowsError(try CentralCatalog(source: source, revision: catalog.revision, workspaces: [], sessions: catalog.sessions))
        XCTAssertThrowsError(try CentralCatalog(source: source, revision: CentralRevision(rawValue: 6)!, workspaces: catalog.workspaces, sessions: catalog.sessions))
        XCTAssertEqual(catalog.sessionsByWorkspace[nil]?.count, 1)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(requests.allSatisfy { CentralRequest.readMethods.contains($0.method) })
    }
    func testNoPartialCatalogSurvivesDuplicateIdentityCapacityOrFinalRevisionChange() async throws {
        for mode in [CentralReplies.Mode.duplicateSession, .capacity, .lateRevision, .lateStore] {
            let source = try source(), fixture = CentralReplies(source: source, mode: mode)
            do {
                _ = try await CentralCatalogLoader.load(source: source) { try await fixture.reply($0) }
                XCTFail("An inconsistent authority must not publish a partial/empty catalog: \(mode)")
            } catch {
                if mode == .lateStore {
                    guard case AxoProtocolValidationError.staleStore = error else { return XCTFail("Store fence") }
                }
            }
        }
    }
}
