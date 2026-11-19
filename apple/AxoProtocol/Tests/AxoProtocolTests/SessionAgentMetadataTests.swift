import Foundation
import XCTest
@testable import AxoProtocol

final class SessionAgentMetadataTests: XCTestCase {
  func testOldMetadataDoesNotInventPiAndKnownAgentRoundTripsToTheClient() throws {
    let old = #"{"name":null,"emoji":null,"folderName":null,"hasAgent":true,"createdAt":null,"lastMessageAt":null,"archived":false}"#
    let decoder = JSONDecoder()
    XCTAssertNil(try decoder.decode(SessionMetadata.self, from: Data(old.utf8)).agent)
    let known = old.dropLast() + #","agent":"codex"}"#
    XCTAssertEqual(try decoder.decode(SessionMetadata.self, from: Data(known.utf8)).agent, .codex)
  }
}
