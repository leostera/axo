import XCTest

@testable import AxoProtocol

final class RelayLinkStatusTests: XCTestCase {
  private func decode(_ extra: String = "") throws -> RemoteAccessStatus {
    let json = #"{"state":"disconnected","hostName":"fixture","hostKind":"macos"\#(extra)}"#
    return try JSONDecoder().decode(RemoteAccessStatus.self, from: Data(json.utf8))
  }

  func testOldAndNullLinkMetadataRemainUnknownRatherThanUnlinked() throws {
    XCTAssertNil(try decode().linked)
    XCTAssertNil(try decode(#", "linked":null"#).linked)
    XCTAssertEqual(try decode().state, .disconnected)
  }

  func testExplicitLinkStateSurvivesDecodingWhileDisconnected() throws {
    XCTAssertEqual(try decode(#", "linked":true"#).linked, true)
    XCTAssertEqual(try decode(#", "linked":false"#).linked, false)
  }

  func testMalformedLinkStateIsRejectedInsteadOfCoerced() {
    for value in [#""false""#, #""true""#, "0", "1", "{}", "[]"] {
      XCTAssertThrowsError(try decode(", \"linked\":\(value)"), value)
    }
  }
}
