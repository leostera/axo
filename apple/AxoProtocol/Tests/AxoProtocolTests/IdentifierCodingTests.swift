import AxoProtocol
import XCTest

final class IdentifierCodingTests: XCTestCase {
  func testShellIdentifiersEncodeAsPlainIntegers() throws {
    let data = try JSONEncoder().encode(SessionLayout.pane(shellID: ShellID(rawValue: 42)))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["shellId"] as? Int, 42)
  }

  func testSessionIdentifiersAreCanonicalLowercaseUUIDStrings() throws {
    let raw = "2f5c3a1e-8d4b-4c6a-9e1f-0b7d3c2a5e41"
    let id = try XCTUnwrap(SessionID(rawValue: raw))
    XCTAssertEqual(String(decoding: try JSONEncoder().encode(id), as: UTF8.self), "\"\(raw)\"")
    // Foundation writes UUIDs uppercase; a Session ID made from one is still lowercase.
    XCTAssertEqual(SessionID(UUID(uuidString: raw)!), id)
    XCTAssertEqual(SessionID(UUID(uuidString: raw)!).rawValue, raw)
    for invalid in [raw.uppercased(), "7", "", "\(raw)0", "{\(raw)}", "2f5c3a1e8d4b4c6a9e1f0b7d3c2a5e41"] {
      XCTAssertNil(SessionID(rawValue: invalid), invalid)
    }
    for invalid in ["7", "\"\(raw.uppercased())\""] {
      XCTAssertThrowsError(try JSONDecoder().decode(SessionID.self, from: Data(invalid.utf8)), invalid)
    }
  }

  func testSessionDecodesTypedIdentifiers() throws {
    let json = Data(
      #"{"id":"00000003-0000-4000-8000-000000000003","initialPwd":"/","shells":[{"id":9,"processId":1,"initialPwd":"/","ptyDevice":"/dev/ttys001","attachSocketPath":"/tmp/a","role":"terminal","available":true,"availabilityReason":null}]}"#
        .utf8)
    let session = try JSONDecoder().decode(TerminalSession.self, from: json)
    XCTAssertEqual(session.id, 3)
    XCTAssertEqual(session.shells.map(\.id), [ShellID(rawValue: 9)])
  }
}
