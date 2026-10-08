import XCTest
@testable import AxoCore

final class ProtocolTests: XCTestCase {
    func testEndpointRejectsCredentialAndInsecureURLs() throws {
        for url in ["http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?token=secret"] {
            XCTAssertThrowsError(try RelayEndpoint(url))
        }
        let endpoint = try RelayEndpoint("https://api.example.com")
        XCTAssertEqual(endpoint.socketURL.absoluteString, "wss://api.example.com/connect/phone")
        XCTAssertEqual(endpoint.loginURL.absoluteString, "https://api.example.com/login")
    }

    func testSnapshotMatchesWireFormat() throws {
        let json = #"{"type":"snapshot","sessionId":"s1","state":"waiting","messages":[{"id":"m1","role":"assistant","text":"Choose a format"}],"question":{"id":"q1","title":"Format?","options":["JSON","Markdown"]}}"#
        guard case .snapshot(let snapshot) = try RelayEvent.decode(Data(json.utf8)) else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.sessionId, "s1")
        XCTAssertEqual(snapshot.question?.options, ["JSON", "Markdown"])
        XCTAssertEqual(snapshot.messages.count, 1)
    }

    func testMalformedAndOversizedFramesFail() {
        XCTAssertThrowsError(try RelayEvent.decode(Data(#"{"type":"presence"}"#.utf8)))
        XCTAssertThrowsError(try RelayEvent.decode(Data(#"{"type":"ack","id":"x","disposition":"executed"}"#.utf8)))
        XCTAssertThrowsError(try RelayEvent.decode(Data(repeating: 32, count: 256 * 1024 + 1)))
    }

    func testPromptsHaveExplicitSessionAndIdentity() throws {
        let command = PhoneCommand.prompt(id: "c1", session: "s1", text: "Hello")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: String])
        XCTAssertEqual(value, ["type": "prompt", "id": "c1", "sessionId": "s1", "text": "Hello"])
    }
}
