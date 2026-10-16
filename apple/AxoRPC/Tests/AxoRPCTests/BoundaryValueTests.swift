import XCTest

@testable import AxoRPC

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

  func testUnixSocketPathMustBeAbsoluteAndFitThePlatformAddress() throws {
    XCTAssertEqual(try UnixSocketPath("/tmp/axod.sock").value, "/tmp/axod.sock")
    XCTAssertThrowsError(try UnixSocketPath("relative/axod.sock"))
    XCTAssertThrowsError(try UnixSocketPath("/tmp/axo\0.sock"))

    let address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    XCTAssertThrowsError(try UnixSocketPath("/" + String(repeating: "x", count: pathCapacity)))
  }
}
