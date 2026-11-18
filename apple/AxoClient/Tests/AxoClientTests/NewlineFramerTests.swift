import Foundation
import XCTest

@testable import AxoClient

final class NewlineFramerTests: XCTestCase {
  private func frame(_ reads: [String], limit: Int = 1024) throws -> [String] {
    var framer = NewlineFramer(maximumMessageBytes: limit)
    var messages: [String] = []
    for read in reads {
      try framer.append(Data(read.utf8)) { messages.append(String(decoding: $0, as: UTF8.self)) }
    }
    return messages
  }

  func testMessagesAreSplitOnNewlinesAcrossAndWithinReads() throws {
    XCTAssertEqual(try frame(["a\nb", "c\n\nd", "e", "\nf"]), ["a", "bc", "de"])
    XCTAssertEqual(try frame(["\n\n"]), [])
    XCTAssertEqual(try frame(["one\ntwo\nthree\n"]), ["one", "two", "three"])
  }

  func testAMessageLongerThanTheLimitEndsTheStream() {
    XCTAssertEqual(try frame(["abcd\n"], limit: 4), ["abcd"])
    XCTAssertThrowsError(try frame(["abcde\n"], limit: 4))
    XCTAssertThrowsError(try frame(["ab", "cde"], limit: 4), "without its newline yet")
    XCTAssertThrowsError(try frame(["ok\nabcde\n"], limit: 4))
  }

  /// A whole-catalog reply at the limit, in the transport's 64 KiB reads, must not be quadratic
  /// (rescanning the buffer on every read took over 8 s for this).
  func testALimitSizedMessageInSmallReadsIsLinear() throws {
    let limit = UnixSocketChannel.maximumMessageBytes
    var stream = Data(repeating: 0x61, count: limit)
    stream.append(0x0A)
    var framer = NewlineFramer(maximumMessageBytes: limit)
    var received = 0
    let start = ContinuousClock.now
    var offset = 0
    while offset < stream.count {
      let end = min(offset + 64 * 1024, stream.count)
      try framer.append(stream.subdata(in: offset..<end)) { received += $0.count }
      offset = end
    }
    XCTAssertEqual(received, limit)
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
  }
}
