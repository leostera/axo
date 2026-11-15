import AxoProtocol
import Darwin
import Foundation
import XCTest

@testable import AxoClient

final class TerminalAttachmentTimeoutTests: XCTestCase {
  func testStalledHandshakeIsARetryableTimeoutNotAPiCrash() throws {
    // A private listener accepts a connection into its backlog but never sends a header.
    // No production daemon, Session, PTY, or process is used.
    let path = "/tmp/axo-attach-timeout-\(UUID().uuidString).sock"
    let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    defer { Darwin.close(listener); unlink(path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { target in
      let bytes = Array(path.utf8) + [0]
      target.copyBytes(from: bytes)
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertEqual(Darwin.listen(listener, 1), 0)
    XCTAssertThrowsError(try TerminalAttachment.open(socketPath: UnixSocketPath(path),
      shellID: ShellID(rawValue: 7), timeout: .milliseconds(20))) { error in
      guard let error = error as? TerminalAttachmentError else { return XCTFail("\(error)") }
      XCTAssertTrue(error.isRetryable)
      XCTAssertTrue(error.description.contains("Timed out"), error.description)
      guard case .system("read", let code) = error else { return XCTFail("\(error)") }
      XCTAssertTrue([EAGAIN, EWOULDBLOCK, ETIMEDOUT].contains(code))
    }
  }

  func testPermissionAndProtocolFailuresAreNotAutomaticallyRetried() {
    for error in [TerminalAttachmentError.system("connect", EACCES), .system("read", EBADF),
      .rejected(.shellNotOpen), .missingDescriptor, .rejected(.other(19))] {
      XCTAssertFalse(error.isRetryable, error.description)
    }
  }
}
