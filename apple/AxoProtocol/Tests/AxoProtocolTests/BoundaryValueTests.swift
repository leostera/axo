import XCTest

@testable import AxoProtocol

final class BoundaryValueTests: XCTestCase {
  func testSessionLayoutHasStableTaggedJsonEncoding() throws {
    let layout = SessionLayout.split(
      id: UUID(uuidString: "02A4C161-8143-4C9A-BBF2-1A625E8B8342")!,
      direction: .right,
      ratio: 0.63,
      first: .pane(shellID: 17),
      second: .split(
        id: UUID(uuidString: "12A4C161-8143-4C9A-BBF2-1A625E8B8342")!,
        direction: .down,
        ratio: 0.42,
        first: .pane(shellID: 23),
        second: .pane(shellID: 42)
      )
    )

    let data = try JSONEncoder().encode(layout)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["kind"] as? String, "split")
    XCTAssertEqual(json["direction"] as? String, "right")
    XCTAssertEqual(json["ratio"] as? Double, 0.63)
    let first = try XCTUnwrap(json["first"] as? [String: Any])
    XCTAssertEqual(first["kind"] as? String, "pane")
    XCTAssertEqual(first["shellId"] as? Int, 17)
    XCTAssertNil(first["shellID"])
    XCTAssertEqual(try JSONDecoder().decode(SessionLayout.self, from: data), layout)
  }

  func testUnavailablePiPaneDecodesWithoutMakingItAttachable() throws {
    let sessionJSON = """
      {
        "id": 7,
        "initialPwd": "/tmp",
        "status": "unavailable",
        "shells": [{
          "id": 19,
          "paneId": "pi-pane",
          "role": "pi",
          "processId": 0,
          "initialPwd": "/tmp",
          "ptyDevice": "",
          "attachSocketPath": "/tmp/attach.sock",
          "available": false,
          "availabilityReason": "Pi recovery failed."
        }],
        "layout": { "kind": "pane", "shellId": 19 }
      }
      """.data(using: .utf8)!

    let session = try JSONDecoder().decode(TerminalSession.self, from: sessionJSON)
    let shell = try XCTUnwrap(session.shells.first)
    XCTAssertEqual(shell.availability, .unavailable(reason: "Pi recovery failed."))
    XCTAssertEqual(shell.role, .pi)
    XCTAssertEqual(session.status, .unavailable)
  }

  func testShellAvailabilityAndRoleMustBeConsistentOnTheWire() throws {
    func shell(_ fields: String) -> Data {
      """
      { "id": 1, "processId": 1, "initialPwd": "/", "ptyDevice": "/dev/ttys001",
        "attachSocketPath": "/tmp/a.sock", \(fields) }
      """.data(using: .utf8)!
    }
    let decoder = JSONDecoder()
    let available = try decoder.decode(
      TerminalShell.self,
      from: shell(#""role": "terminal", "available": true, "availabilityReason": null"#))
    XCTAssertEqual(available.availability, .available)
    XCTAssertEqual(available.role, .terminal)

    for invalid in [
      #""role": "terminal", "available": true, "availabilityReason": "why""#,
      #""role": "terminal", "available": false, "availabilityReason": null"#,
      #""role": "terminal", "available": false, "availabilityReason": """#,
      #""role": "terminal", "availabilityReason": null"#,
      #""role": "robot", "available": true, "availabilityReason": null"#,
      #""available": true, "availabilityReason": null"#,
    ] {
      XCTAssertThrowsError(try decoder.decode(TerminalShell.self, from: shell(invalid)), invalid)
    }
  }

  func testBuildNumbersMustBePositiveCanonicalIntegers() {
    XCTAssertEqual(BuildNumber(bundleValue: "42")?.value, 42)
    XCTAssertNil(BuildNumber(bundleValue: "0"))
    XCTAssertNil(BuildNumber(bundleValue: "042"))
    XCTAssertNil(BuildNumber(bundleValue: "4.2"))
    XCTAssertNil(BuildNumber(bundleValue: 42))
  }

  func testPairingCodeParsingNormalizesOnlyTheExpectedCodeShape() {
    XCTAssertEqual(HostPairingCode(parsing: " b26a-nrkt\n")?.value, "B26A-NRKT")
    XCTAssertNil(HostPairingCode(parsing: "B26A-IRKT"))
    XCTAssertNil(HostPairingCode(parsing: "B26A-NRKT-extra"))
    XCTAssertNil(HostPairingCode(parsing: "B26A NRKT"))
  }

  func testPairingDeepLinkAcceptsOnlyTheAxoPairRoute() throws {
    XCTAssertEqual(
      HostPairingCode.fromPairingURL(try XCTUnwrap(URL(string: "axo://pair/B26A-NRKT")))?.value,
      "B26A-NRKT"
    )
    XCTAssertNil(
      HostPairingCode.fromPairingURL(
        try XCTUnwrap(URL(string: "https://axo.leostera.dev/pair/B26A-NRKT"))))
    XCTAssertNil(
      HostPairingCode.fromPairingURL(try XCTUnwrap(URL(string: "axo://other/B26A-NRKT"))))
    XCTAssertNil(
      HostPairingCode.fromPairingURL(try XCTUnwrap(URL(string: "axo://pair/B26A-NRKT/extra"))))
    XCTAssertNil(
      HostPairingCode.fromPairingURL(
        try XCTUnwrap(URL(string: "axo://pair/B26A-NRKT?redirect=https://example.test"))))
    XCTAssertNil(
      HostPairingCode.fromPairingURL(try XCTUnwrap(URL(string: "axo://pair/B26A%2DNRKT"))))
  }
}
