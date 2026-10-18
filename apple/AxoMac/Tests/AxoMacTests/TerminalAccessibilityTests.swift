import Foundation
import XCTest

@testable import AxoMac

final class TerminalAccessibilityTests: XCTestCase {
  func testSnapshotUsesUTF16RangesAndBoundsUTF8Payload() {
    let visible = "a\n🙂e\u{301}"
    XCTAssertEqual(TerminalAccessibilitySnapshot.line(for: 4, in: visible), 1)
    XCTAssertEqual(
      TerminalAccessibilitySnapshot.string(visible, in: NSRange(location: 2, length: 2)), "🙂")
    XCTAssertEqual(
      TerminalAccessibilitySnapshot.selectedRange(
        NSRange(location: 0, length: 2), visibleText: visible),
      NSRange(location: 0, length: 2))
    XCTAssertEqual(
      TerminalAccessibilitySnapshot.selectedRange(
        NSRange(location: 99, length: 0), visibleText: visible).location,
      NSNotFound)

    let bounded = TerminalAccessibilitySnapshot.bounded(String(repeating: "🙂", count: 20_000))
    XCTAssertLessThanOrEqual(bounded.utf8.count, TerminalAccessibilitySnapshot.maximumUTF8Bytes)
    XCTAssertTrue(bounded.utf8.count.isMultiple(of: 4))
  }
}
