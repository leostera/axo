import Foundation
import XCTest
@testable import AxoProtocol

final class AxoProtocolTests: XCTestCase {
    func testSharedEnvelopeFixtures() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/envelopes.json")
        let fixtures = try JSONDecoder().decode([EnvelopeFixture].self, from: Data(contentsOf: fixtureURL))

        for fixture in fixtures {
            do {
                let message = try AxoProtocolCodec.decode(fixture.raw)
                let actualErrors = message.entries.compactMap { entry -> Int? in
                    if case .invalid(let failure) = entry { return failure.error.code }
                    return nil
                }
                XCTAssertEqual(actualErrors, fixture.errors, fixture.name)
            } catch let error as RPCProtocolError {
                XCTAssertEqual([error.code], fixture.errors, fixture.name)
            }
        }
    }

    func testAbsentAndNullRequestIDsRemainDistinct() throws {
        let notification = try AxoProtocolCodec.decode("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}")
        let nullIDRequest = try AxoProtocolCodec.decode("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"test\"}")

        guard case .request(let notificationRequest) = notification.entries[0],
              case .request(let nullIDRequestValue) = nullIDRequest.entries[0]
        else { return XCTFail("Expected valid requests") }

        XCTAssertNil(notificationRequest.id)
        XCTAssertEqual(nullIDRequestValue.id, .null)
    }

    func testFrameLimitUsesEncodedUTF8Bytes() throws {
        let multibyte = String(repeating: "é", count: AxoProtocolCodec.maximumFrameBytes / 2 + 1)
        XCTAssertThrowsError(try AxoProtocolCodec.decode(multibyte)) { error in
            XCTAssertEqual((error as? RPCProtocolError)?.code, -32600)
        }
    }

    func testResponsesRequireExactlyOneResultOrErrorAndPreserveNullResults() throws {
        let decoder = JSONDecoder()
        let response = try decoder.decode(
            RPCResponse.self,
            from: Data(#"{"jsonrpc":"2.0","id":null,"result":null}"#.utf8)
        )
        XCTAssertEqual(response, .result(id: .null, value: .null))

        XCTAssertThrowsError(try decoder.decode(
            RPCResponse.self,
            from: Data(#"{"jsonrpc":"2.0","id":1,"result":null,"error":{"code":1,"message":"bad"}}"#.utf8)
        ))
    }

    func testTerminalProcessUsesWireDiscriminatorsAndSnakeCaseFields() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(TerminalProcess.exited(waitStatus: 7))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "{\"kind\":\"exited\",\"wait_status\":7}")

        let decoded = try JSONDecoder().decode(TerminalProcess.self, from: encoded)
        XCTAssertEqual(decoded, .exited(waitStatus: 7))
    }

    func testMethodValidatorsCheckNegotiationAndMachineListSemantics() throws {
        let negotiation = try value(#"{"protocolVersion":1,"methods":["axo.runtime.list"],"deliveryCredits":{"frames":32,"bytes":131072}}"#)
        XCTAssertEqual(try AxoProtocolResultValidator.negotiation(negotiation).protocolVersion, 1)
        XCTAssertThrowsError(try AxoProtocolResultValidator.negotiation(value(
            #"{"protocolVersion":1,"methods":["axo.runtime.list"],"deliveryCredits":{"frames":33,"bytes":131072}}"#
        )))

        let machines = try value(#"{"machines":[{"machineId":"11111111-1111-4111-8111-111111111111","label":"Online host","online":true,"hostGeneration":"22222222-2222-4222-8222-222222222222"},{"machineId":"33333333-3333-4333-8333-333333333333","label":"Offline host","online":false,"hostGeneration":null}]}"#)
        XCTAssertEqual(try AxoProtocolResultValidator.machineList(machines).machines.count, 2)

        let inconsistentPresence = try value(#"{"machines":[{"machineId":"11111111-1111-4111-8111-111111111111","label":"Offline host","online":true,"hostGeneration":null}]}"#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.machineList(inconsistentPresence))

        let unexpectedMetadata = try value(#"{"machines":[],"conversationHistory":[]}"#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.machineList(unexpectedMetadata))
    }

    func testRuntimeValidatorAcceptsHistoricalRecordsAndRejectsStaleOrUnboundedResults() throws {
        let machineID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let currentGeneration = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let historicalGeneration = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let target = MachineTarget(machineId: machineID, hostGeneration: currentGeneration)
        let result = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","terminals":[{"runtime":{"host_generation":"33333333-3333-4333-8333-333333333333","target":{"session_id":"44444444-4444-4444-8444-444444444444","pane_id":"55555555-5555-4555-8555-555555555555"},"runtime_generation":"66666666-6666-4666-8666-666666666666"},"process":{"kind":"exited","wait_status":0},"attached":false,"backlog_bytes":8192}],"next":null}"#)
        let decoded = try AxoProtocolResultValidator.runtimeList(result, target: target)
        XCTAssertEqual(decoded.hostGeneration, currentGeneration)
        XCTAssertEqual(decoded.terminals.first?.runtime.hostGeneration, historicalGeneration)

        let stale = try value(#"{"hostGeneration":"33333333-3333-4333-8333-333333333333","terminals":[],"next":null}"#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.runtimeList(stale, target: target)) { error in
            XCTAssertEqual(error as? AxoProtocolValidationError, .staleHost(expected: currentGeneration, actual: historicalGeneration))
        }

        let oversizedBacklog = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","terminals":[{"runtime":{"host_generation":"22222222-2222-4222-8222-222222222222","target":{"session_id":"44444444-4444-4444-8444-444444444444","pane_id":"55555555-5555-4555-8555-555555555555"},"runtime_generation":"66666666-6666-4666-8666-666666666666"},"process":{"kind":"running","pid":42},"attached":true,"backlog_bytes":8193}],"next":null}"#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.runtimeList(oversizedBacklog, target: target))
    }

    func testWorkRecordPagesValidateRevisionScopeTargetAndPiAdmission() throws {
        let machine = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let host = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let workspace = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let session = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let pane = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let target = MachineTarget(machineId: machine, hostGeneration: host)

        let directories = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","directories":[{"directoryId":"approved","name":"Approved"}]}"#)
        XCTAssertEqual(try AxoProtocolResultValidator.workspaceDirectories(directories, target: target).directories.first?.directoryId, "approved")
        let staleDirectories = try value(#"{"hostGeneration":"99999999-9999-4999-8999-999999999999","directories":[]}"#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.workspaceDirectories(staleDirectories, target: target))

        let workspacePage = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":7,"workspaces":[{"workspaceId":"33333333-3333-4333-8333-333333333333","name":"Axo 😃","directoryId":"approved"}],"next":{"target":{"machineId":"11111111-1111-4111-8111-111111111111","hostGeneration":"22222222-2222-4222-8222-222222222222"},"revision":7,"scope":{"kind":"workspaces"},"after":"33333333-3333-4333-8333-333333333333"}}"#)
        let decodedWorkspaces = try AxoProtocolResultValidator.workspaceList(workspacePage, target: target)
        XCTAssertEqual(decodedWorkspaces.workspaces.first?.workspaceId, workspace)
        XCTAssertEqual(decodedWorkspaces.revision.rawValue, 7)
        XCTAssertEqual(decodedWorkspaces.next?.scope, .workspaces)

        let sessionPage = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":8,"sessions":[{"sessionId":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333","name":"iOS work","nameSource":"manual","pi":{"paneId":"55555555-5555-4555-8555-555555555555","chatId":null,"admission":"notAdmitted"},"runtime":null}],"next":{"target":{"machineId":"11111111-1111-4111-8111-111111111111","hostGeneration":"22222222-2222-4222-8222-222222222222"},"revision":8,"scope":{"kind":"sessions","workspaceId":"33333333-3333-4333-8333-333333333333"},"after":"44444444-4444-4444-8444-444444444444"}}"#)
        let decodedSessions = try AxoProtocolResultValidator.sessionList(sessionPage, target: target, workspaceID: workspace)
        XCTAssertEqual(decodedSessions.sessions.first?.pi.admission, .notAdmitted)
        XCTAssertNil(decodedSessions.sessions.first?.runtime)
        XCTAssertEqual(decodedSessions.next?.scope, .sessions(workspaceId: workspace))

        let wrongScope = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":8,"sessions":[{"sessionId":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333","name":"iOS work","nameSource":"manual","pi":{"paneId":"55555555-5555-4555-8555-555555555555","chatId":null,"admission":"notAdmitted"},"runtime":null}],"next":{"target":{"machineId":"11111111-1111-4111-8111-111111111111","hostGeneration":"22222222-2222-4222-8222-222222222222"},"revision":8,"scope":{"kind":"sessions","workspaceId":null},"after":"44444444-4444-4444-8444-444444444444"}}"#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionList(wrongScope, target: target, workspaceID: workspace))

        let inconsistentAdmission = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":8,"sessions":[{"sessionId":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333","name":"iOS work","nameSource":"manual","pi":{"paneId":"55555555-5555-4555-8555-555555555555","chatId":"66666666-6666-4666-8666-666666666666","admission":"notAdmitted"},"runtime":null}],"next":null}"#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionList(inconsistentAdmission, target: target, workspaceID: workspace))

        let get = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":8,"session":{"sessionId":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333","name":"iOS work","nameSource":"manual","pi":{"paneId":"55555555-5555-4555-8555-555555555555","chatId":null,"admission":"notAdmitted"},"runtime":null}}"#)
        let detail = try AxoProtocolResultValidator.sessionGet(get, target: WorkSessionTarget(machineId: machine, hostGeneration: host, workspaceId: workspace, sessionId: session))
        XCTAssertEqual(detail.session.pi.paneId, pane)
    }

    func testWorkRequestsEncodeWireShapesAndValidateFiltersAndNames() throws {
        let machine = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let host = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let workspace = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let target = MachineTarget(machineId: machine, hostGeneration: host)
        let revision = WorkRevision(rawValue: 7)!
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let list = WorkspaceListParameters(target: target, limit: 20)
        try AxoProtocolWorkRequestValidator.validate(list)
        let encodedList = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(list))
        XCTAssertEqual(encodedList, try value(#"{"limit":20,"target":{"hostGeneration":"22222222-2222-4222-8222-222222222222","machineId":"11111111-1111-4111-8111-111111111111"}}"#))

        let cursor = WorkPageCursor(target: target, revision: revision, scope: .sessions(workspaceId: workspace), after: workspace)
        let sessionList = SessionListParameters(target: target, workspaceId: workspace, cursor: cursor, limit: 10)
        try AxoProtocolWorkRequestValidator.validate(sessionList)
        let encodedSessionList = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(sessionList))
        XCTAssertEqual(encodedSessionList, try value(#"{"cursor":{"after":"33333333-3333-4333-8333-333333333333","revision":7,"scope":{"kind":"sessions","workspaceId":"33333333-3333-4333-8333-333333333333"},"target":{"hostGeneration":"22222222-2222-4222-8222-222222222222","machineId":"11111111-1111-4111-8111-111111111111"}},"limit":10,"target":{"hostGeneration":"22222222-2222-4222-8222-222222222222","machineId":"11111111-1111-4111-8111-111111111111"},"workspaceId":"33333333-3333-4333-8333-333333333333"}"#))

        let sessionTarget = WorkSessionTarget(
            machineId: machine, hostGeneration: host, workspaceId: workspace,
            sessionId: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        )
        let sessionGet = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(SessionGetParameters(target: sessionTarget)))
        XCTAssertEqual(sessionGet, try value(#"{"target":{"hostGeneration":"22222222-2222-4222-8222-222222222222","machineId":"11111111-1111-4111-8111-111111111111","sessionId":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333"}}"#))
        let commandId = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let commandGet = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(CommandGetParameters(target: target, commandId: commandId)))
        XCTAssertEqual(commandGet, try value(#"{"commandId":"88888888-8888-4888-8888-888888888888","target":{"hostGeneration":"22222222-2222-4222-8222-222222222222","machineId":"11111111-1111-4111-8111-111111111111"}}"#))
        XCTAssertEqual([
            AxoProtocol.Method.listWorkspaceDirectories, AxoProtocol.Method.listWorkspaces, AxoProtocol.Method.createWorkspace, AxoProtocol.Method.renameWorkspace,
            AxoProtocol.Method.listSessions, AxoProtocol.Method.getSession, AxoProtocol.Method.createSession,
            AxoProtocol.Method.renameSession, AxoProtocol.Method.getCommand,
        ], ["axo.workspace.directories", "axo.workspace.list", "axo.workspace.create", "axo.workspace.rename", "axo.session.list", "axo.session.get", "axo.session.create", "axo.session.rename", "axo.command.get"])

        try AxoProtocolWorkRequestValidator.validate(WorkspaceCreateParameters(
            target: target, commandId: UUID(), expectedRevision: revision, directoryId: "approved", name: "Axo"
        ))
        try AxoProtocolWorkRequestValidator.validate(WorkspaceRenameParameters(
            target: WorkWorkspaceTarget(machineId: machine, hostGeneration: host, workspaceId: workspace),
            commandId: UUID(), expectedRevision: revision, name: "Renamed"
        ))
        try AxoProtocolWorkRequestValidator.validate(SessionCreateParameters(
            target: WorkWorkspaceTarget(machineId: machine, hostGeneration: host, workspaceId: workspace),
            commandId: UUID(), expectedRevision: revision, name: "New session"
        ))
        try AxoProtocolWorkRequestValidator.validate(SessionRenameParameters(
            target: WorkSessionTarget(machineId: machine, hostGeneration: host, workspaceId: workspace, sessionId: UUID()),
            commandId: UUID(), expectedRevision: revision, name: "Renamed session"
        ))

        XCTAssertThrowsError(try AxoProtocolWorkRequestValidator.validate(WorkspaceListParameters(target: target, limit: 0)))
        XCTAssertThrowsError(try AxoProtocolWorkRequestValidator.validate(SessionListParameters(
            target: target, workspaceId: workspace,
            cursor: WorkPageCursor(target: target, revision: revision, scope: .sessions(workspaceId: nil), after: workspace)
        )))
        XCTAssertThrowsError(try AxoProtocolWorkRequestValidator.validate(WorkspaceCreateParameters(
            target: target, commandId: UUID(), expectedRevision: revision, directoryId: "approved", name: " padded "
        )))
        XCTAssertNil(WorkRevision(rawValue: WorkRevision.maximumSafeInteger + 1))
    }

    func testWorkMutationAndCommandReceiptResultsAreStrictlyFenced() throws {
        let machine = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let host = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let workspace = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let session = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let pane = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let machineTarget = MachineTarget(machineId: machine, hostGeneration: host)
        let workspaceTarget = WorkWorkspaceTarget(machineId: machine, hostGeneration: host, workspaceId: workspace)
        let sessionTarget = WorkSessionTarget(machineId: machine, hostGeneration: host, workspaceId: workspace, sessionId: session)

        let createdWorkspace = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":5,"workspace":{"workspaceId":"33333333-3333-4333-8333-333333333333","name":"Axo","directoryId":"approved"}}"#)
        XCTAssertEqual(try AxoProtocolResultValidator.workspaceCreate(
            createdWorkspace, target: machineTarget, expectedRevision: WorkRevision(rawValue: 4)!, name: "Axo", directoryID: "approved"
        ).revision.rawValue, 5)

        let renamedWorkspace = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":6,"workspace":{"workspaceId":"33333333-3333-4333-8333-333333333333","name":"Renamed","directoryId":"approved"}}"#)
        XCTAssertEqual(try AxoProtocolResultValidator.workspaceRename(
            renamedWorkspace, target: workspaceTarget, expectedRevision: WorkRevision(rawValue: 5)!, name: "Renamed"
        ).workspace.workspaceId, workspace)

        let createdSession = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":7,"session":{"sessionId":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333","name":"Session","nameSource":"manual","pi":{"paneId":"55555555-5555-4555-8555-555555555555","chatId":null,"admission":"notAdmitted"},"runtime":null}}"#)
        XCTAssertEqual(try AxoProtocolResultValidator.sessionCreate(
            createdSession, target: workspaceTarget, expectedRevision: WorkRevision(rawValue: 6)!, name: "Session"
        ).session.pi.paneId, pane)

        let renamedSession = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":8,"session":{"sessionId":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333","name":"Renamed session","nameSource":"manual","pi":{"paneId":"55555555-5555-4555-8555-555555555555","chatId":null,"admission":"notAdmitted"},"runtime":null}}"#)
        XCTAssertEqual(try AxoProtocolResultValidator.sessionRename(
            renamedSession, target: sessionTarget, expectedRevision: WorkRevision(rawValue: 7)!, name: "Renamed session"
        ).session.sessionId, session)

        let wrongRevision = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","revision":9,"workspace":{"workspaceId":"33333333-3333-4333-8333-333333333333","name":"Axo","directoryId":"approved"}}"#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.workspaceCreate(
            wrongRevision, target: machineTarget, expectedRevision: WorkRevision(rawValue: 4)!, name: "Axo", directoryID: "approved"
        ))
        let absentReceipt = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","receipt":null}"#)
        XCTAssertNil(try AxoProtocolResultValidator.commandGet(absentReceipt, target: machineTarget).receipt)

        let workReceipt = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","receipt":{"kind":"work","committed":{"revision":9,"record":{"kind":"session","record":{"sessionId":"44444444-4444-4444-8444-444444444444","workspaceId":"33333333-3333-4333-8333-333333333333","name":"Session","piPaneId":"55555555-5555-4555-8555-555555555555"}}}}}"#)
        let receiptResult = try AxoProtocolResultValidator.commandGet(workReceipt, target: machineTarget)
        guard case .work(let committed)? = receiptResult.receipt,
              case .session(let committedSession) = committed.record
        else { return XCTFail("Expected committed work-session receipt") }
        XCTAssertEqual(committedSession.sessionId, session)

        let runtimeReceipt = try value(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","receipt":{"kind":"runtime","runtime":{"host_generation":"77777777-7777-4777-8777-777777777777","target":{"session_id":"44444444-4444-4444-8444-444444444444","pane_id":"55555555-5555-4555-8555-555555555555"},"runtime_generation":"66666666-6666-4666-8666-666666666666"},"terminal":{"runtime":{"host_generation":"77777777-7777-4777-8777-777777777777","target":{"session_id":"44444444-4444-4444-8444-444444444444","pane_id":"55555555-5555-4555-8555-555555555555"},"runtime_generation":"66666666-6666-4666-8666-666666666666"},"process":{"kind":"running","pid":42},"attached":true,"backlog_bytes":0}}}"#)
        guard case .runtime(let runtime, let terminal)? = try AxoProtocolResultValidator.commandGet(runtimeReceipt, target: machineTarget).receipt
        else { return XCTFail("Expected original runtime receipt") }
        XCTAssertEqual(runtime.target.sessionId, session)
        XCTAssertEqual(terminal?.process, .running(pid: 42))
    }

    func testNegotiationAcceptsExpandedBoundedMethodCatalog() throws {
        let methods = (0..<20).map { "axo.example.method\($0)" } + [AxoProtocol.Method.listRuntimes]
        let data = try JSONEncoder().encode(ProtocolNegotiationResult(
            protocolVersion: AxoProtocol.version,
            methods: methods,
            deliveryCredits: .init(frames: AxoProtocol.deliveryCreditFrameCount, bytes: AxoProtocol.deliveryCreditBytes)
        ))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(try AxoProtocolResultValidator.negotiation(value).methods.count, 21)
    }

    func testResponseFrameDecoderPreservesBatchAndEnforcesBounds() throws {
        let batch = try AxoProtocolCodec.decodeResponses(#"[{"jsonrpc":"2.0","id":"a","result":{}},{"jsonrpc":"2.0","id":"b","result":null}]"#)
        XCTAssertTrue(batch.isBatch)
        XCTAssertEqual(batch.responses.count, 2)
        XCTAssertThrowsError(try AxoProtocolCodec.decodeResponses("[\(Array(repeating: #"{"jsonrpc":"2.0","id":"a","result":null}"#, count: 9).joined(separator: ","))]"))
        XCTAssertThrowsError(try AxoProtocolCodec.decodeResponses(String(repeating: "x", count: AxoProtocolCodec.maximumFrameBytes + 1)))
    }

    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private struct EnvelopeFixture: Decodable {
        let name: String
        let raw: String
        let errors: [Int]
    }
}
