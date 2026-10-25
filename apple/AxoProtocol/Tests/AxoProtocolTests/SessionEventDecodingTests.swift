import AxoProtocol
import XCTest

final class SessionEventDecodingTests: XCTestCase {
  private func decode(_ json: String) throws -> TerminalSessionEvent {
    try JSONDecoder().decode(TerminalSessionEvent.self, from: Data(json.utf8))
  }

  func testTerminalOutputCarriesItsDecodedBytes() throws {
    let event = try decode(
      #"{"type":"terminal.output","sessionId":1,"shellId":2,"sequence":3,"data":"aGk="}"#)
    XCTAssertEqual(
      event, .terminalOutput(sessionID: 1, shellID: 2, sequence: 3, data: Data("hi".utf8)))
  }

  func testTerminalOutputThatIsNotBase64IsADecodingError() {
    XCTAssertThrowsError(
      try decode(
        #"{"type":"terminal.output","sessionId":1,"shellId":2,"sequence":3,"data":"%%"}"#)
    ) { error in
      guard case DecodingError.dataCorrupted = error else {
        return XCTFail("expected dataCorrupted, got \(error)")
      }
    }
  }

  func testUnknownEventTypesAreKeptRatherThanRejected() throws {
    XCTAssertEqual(try decode(#"{"type":"future.event"}"#), .unknown(type: "future.event"))
  }
}
