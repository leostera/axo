import AxoProtocol
import XCTest

final class SessionEventDecodingTests: XCTestCase {
  private func decode(_ json: String) throws -> TerminalSessionEvent {
    try JSONDecoder().decode(TerminalSessionEvent.self, from: Data(json.utf8))
  }

  func testTerminalOutputCarriesItsDecodedBytes() throws {
    let event = try decode(
      #"{"type":"terminal.output","sessionId":"00000001-0000-4000-8000-000000000001","shellId":2,"sequence":3,"data":"aGk="}"#)
    XCTAssertEqual(
      event, .terminalOutput(sessionID: 1, shellID: 2, sequence: 3, data: Data("hi".utf8)))
  }

  func testTerminalOutputThatIsNotBase64IsADecodingError() {
    XCTAssertThrowsError(
      try decode(
        #"{"type":"terminal.output","sessionId":"00000001-0000-4000-8000-000000000001","shellId":2,"sequence":3,"data":"%%"}"#)
    ) { error in
      guard case DecodingError.dataCorrupted = error else {
        return XCTFail("expected dataCorrupted, got \(error)")
      }
    }
  }

  func testQuestionsToThePersonSayWhoAsks() throws {
    let asked = try decode(
      #"{"type":"elicitation.requested","elicitation":{"id":"6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a","sessionId":"00000001-0000-4000-8000-000000000001","kind":"confirm","askedBy":"computerUse","message":"Computer use wants to:","createdAt":1,"expiresAt":2}}"#)
    guard case .elicitationRequested(let elicitation) = asked else { return XCTFail("\(asked)") }
    XCTAssertEqual(elicitation.askedBy, .computerUse)
    XCTAssertEqual(elicitation.sessionId, 1)
    XCTAssertEqual(
      try decode(
        #"{"type":"elicitation.resolved","id":"6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a","sessionId":"00000001-0000-4000-8000-000000000001","action":"accept"}"#),
      .elicitationResolved(id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a", sessionID: 1, action: .accept))
  }

  func testAnOlderAxodsQuestionsAreTheAgents() throws {
    let elicitation = try JSONDecoder().decode(
      Elicitation.self,
      from: Data(
        #"{"id":"6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a","sessionId":"00000001-0000-4000-8000-000000000001","kind":"confirm","message":"Go?","createdAt":1,"expiresAt":2}"#.utf8))
    XCTAssertEqual(elicitation.askedBy, .agent)
  }

  func testUnknownEventTypesAreKeptRatherThanRejected() throws {
    XCTAssertEqual(try decode(#"{"type":"future.event"}"#), .unknown(type: "future.event"))
  }
}
