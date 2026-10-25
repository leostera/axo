import XCTest

import AxoProtocol
@testable import AxoRPC

final class UnixSocketPathTests: XCTestCase {
  func testUnixSocketPathMustBeAbsoluteAndFitThePlatformAddress() throws {
    XCTAssertEqual(try UnixSocketPath("/tmp/axod.sock").value, "/tmp/axod.sock")
    XCTAssertThrowsError(try UnixSocketPath("relative/axod.sock"))
    XCTAssertThrowsError(try UnixSocketPath("/tmp/axo\0.sock"))

    let address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    XCTAssertThrowsError(try UnixSocketPath("/" + String(repeating: "x", count: pathCapacity)))
  }
}
