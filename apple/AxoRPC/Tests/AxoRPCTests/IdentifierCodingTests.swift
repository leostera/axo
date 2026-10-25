import AxoRPC
import XCTest

final class IdentifierCodingTests: XCTestCase {
  func testIdentifiersEncodeAsPlainIntegers() throws {
    let data = try JSONEncoder().encode(SessionLayout.pane(shellID: ShellID(rawValue: 42)))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["shellId"] as? Int, 42)
    XCTAssertEqual(String(decoding: try JSONEncoder().encode(SessionID(rawValue: 7)), as: UTF8.self), "7")
  }

  func testSessionDecodesTypedIdentifiers() throws {
    let json = Data(
      #"{"id":3,"initialPwd":"/","shells":[{"id":9,"processId":1,"initialPwd":"/","ptyDevice":"/dev/ttys001","attachSocketPath":"/tmp/a","role":"terminal","available":true,"availabilityReason":null}]}"#
        .utf8)
    let session = try JSONDecoder().decode(TerminalSession.self, from: json)
    XCTAssertEqual(session.id, SessionID(rawValue: 3))
    XCTAssertEqual(session.shells.map(\.id), [ShellID(rawValue: 9)])
  }
}
