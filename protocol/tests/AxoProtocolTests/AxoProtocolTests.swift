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

    private struct EnvelopeFixture: Decodable {
        let name: String
        let raw: String
        let errors: [Int]
    }
}
