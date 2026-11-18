import AxoProtocol
import Foundation
import XCTest

@testable import AxoClient

/// A new Session names its agent as axod does, and leaves Pi unsaid (RFD0072).
final class CodingAgentTests: XCTestCase {
  func testTheAgentIsNamedAsAxodNamesItAndPiIsLeftUnsaid() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let pi = SessionCreateRequest(folder: nil, like: nil, name: nil)
    XCTAssertEqual(String(decoding: try encoder.encode(pi), as: UTF8.self), "{}")
    let claude = SessionCreateRequest(folder: nil, like: nil, name: nil, agent: .claudeCode)
    XCTAssertEqual(String(decoding: try encoder.encode(claude), as: UTF8.self), #"{"agent":"claude-code"}"#)
    XCTAssertEqual(CodingAgent.allCases.map(\.rawValue), ["pi", "codex", "opencode", "claude-code"])
    XCTAssertEqual(try JSONDecoder().decode(CodingAgent.self, from: Data(#""opencode""#.utf8)), .opencode)
  }
}
