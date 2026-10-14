import XCTest

@testable import AxoRPC

final class BoundaryValueTests: XCTestCase {
  func testBuildNumbersMustBePositiveCanonicalIntegers() {
    XCTAssertEqual(BuildNumber(bundleValue: "42")?.value, 42)
    XCTAssertNil(BuildNumber(bundleValue: "0"))
    XCTAssertNil(BuildNumber(bundleValue: "042"))
    XCTAssertNil(BuildNumber(bundleValue: "4.2"))
    XCTAssertNil(BuildNumber(bundleValue: 42))
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
