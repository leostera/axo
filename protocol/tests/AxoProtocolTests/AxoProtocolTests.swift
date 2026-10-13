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
