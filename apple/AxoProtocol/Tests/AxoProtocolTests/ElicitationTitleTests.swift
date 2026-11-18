import Foundation
import XCTest
@testable import AxoProtocol

final class ElicitationTitleTests: XCTestCase {
  func testTitleIsIndependentOfTheEntireRequestAndOptionalForOlderDaemons() throws {
    let base = """
      {"id":"6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a","sessionId":"00000001-0000-4000-8000-000000000001",
       "kind":"confirm","askedBy":"agent","message":"Deploy the relay only? No mail or billing changes.",
       "createdAt":1,"expiresAt":2}
      """
    let old = try JSONDecoder().decode(Elicitation.self, from: Data(base.utf8))
    XCTAssertNil(old.title)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
    object["title"] = "Release approval"
    let titled = try JSONDecoder().decode(Elicitation.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(titled.title, "Release approval")
    XCTAssertEqual(titled.message, old.message)
  }
}
