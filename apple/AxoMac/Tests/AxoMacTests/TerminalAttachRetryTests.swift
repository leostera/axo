import AxoClient
import AxoProtocol
import Darwin
import XCTest

@testable import AxoMac

final class TerminalAttachRetryTests: XCTestCase {
  func testTransientAttachFailuresBackOffThenStopUntilExplicitRetry() {
    let shell = ShellID(rawValue: 7)
    var policy = TerminalAttachRetry()
    for delay in TerminalAttachRetry.delays {
      XCTAssertEqual(policy.delay(after: TerminalAttachmentError.system("read", EAGAIN), for: shell), delay)
    }
    for _ in 0..<20 { XCTAssertNil(policy.delay(after: TerminalAttachmentError.closed, for: shell)) }
    policy.forget(shell)
    XCTAssertEqual(policy.delay(after: TerminalAttachmentError.closed, for: shell), .seconds(2))
  }

  func testPermanentFailureDoesNotRetryOrConsumeAnotherShellsBudget() {
    let first = ShellID(rawValue: 7), second = ShellID(rawValue: 8)
    var policy = TerminalAttachRetry()
    for error in [TerminalAttachmentError.missingDescriptor, .rejected(.shellNotOpen),
      .rejected(.other(99)), .system("connect", EACCES)] {
      XCTAssertNil(policy.delay(after: error, for: first))
    }
    XCTAssertEqual(policy.delay(after: TerminalAttachmentError.closed, for: first), .seconds(2))
    XCTAssertEqual(policy.delay(after: TerminalAttachmentError.closed, for: first), .seconds(4))
    XCTAssertEqual(policy.delay(after: TerminalAttachmentError.rejected(.daemonBusy), for: second), .seconds(2))
    policy.forget(first)
    XCTAssertEqual(policy.delay(after: TerminalAttachmentError.closed, for: second), .seconds(4))
  }
}
