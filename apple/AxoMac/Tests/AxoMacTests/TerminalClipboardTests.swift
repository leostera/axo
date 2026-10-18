import AppKit
import Foundation
import GhosttyKit
import XCTest

@testable import AxoMac

final class TerminalClipboardTests: XCTestCase {
  func testAccessibilitySnapshotUsesUTF16RangesAndBoundsUTF8Payload() {
    let visible = "a\n🙂e\u{301}"
    XCTAssertEqual(TerminalAccessibilitySnapshot.line(for: 4, in: visible), 1)
    XCTAssertEqual(TerminalAccessibilitySnapshot.string(visible, in: NSRange(location: 2, length: 2)), "🙂")
    XCTAssertEqual(
      TerminalAccessibilitySnapshot.selectedRange(NSRange(location: 0, length: 2), visibleText: visible),
      NSRange(location: 0, length: 2))
    XCTAssertEqual(
      TerminalAccessibilitySnapshot.selectedRange(NSRange(location: 99, length: 0), visibleText: visible).location,
      NSNotFound)

    let bounded = TerminalAccessibilitySnapshot.bounded(String(repeating: "🙂", count: 20_000))
    XCTAssertLessThanOrEqual(bounded.utf8.count, TerminalAccessibilitySnapshot.maximumUTF8Bytes)
    XCTAssertTrue(bounded.utf8.count.isMultiple(of: 4))
  }

  func testConsentRequiresExplicitAllowAndRejectsDenyOrCancel() {
    XCTAssertTrue(TerminalClipboardConsent.isApproved(.alertSecondButtonReturn))
    XCTAssertFalse(TerminalClipboardConsent.isApproved(.alertFirstButtonReturn))
    XCTAssertFalse(TerminalClipboardConsent.isApproved(.cancel))
  }

  func testOnlyOneValidPlainTextRepresentationCanBeWritten() {
    XCTAssertEqual(
      TerminalClipboardPolicy.textContent(from: [
        TerminalClipboardContent(mimeType: "text/plain", data: Data("hello".utf8)),
        TerminalClipboardContent(mimeType: "image/png", data: Data([1, 2, 3])),
      ]),
      "hello")
    XCTAssertNil(
      TerminalClipboardPolicy.textContent(from: [
        TerminalClipboardContent(mimeType: "image/png", data: Data([1, 2, 3]))
      ]))
    XCTAssertNil(
      TerminalClipboardPolicy.textContent(from: [
        TerminalClipboardContent(mimeType: "text/plain", data: Data([0xff])),
      ]))
    XCTAssertNil(
      TerminalClipboardPolicy.textContent(from: [
        TerminalClipboardContent(mimeType: "text/plain", data: Data("one".utf8)),
        TerminalClipboardContent(mimeType: "text/plain", data: Data("two".utf8)),
      ]))
  }

  func testSelectionClipboardHasAnAxoOwnedPasteboardAndOnlyAdvertisesPlainText() {
    XCTAssertEqual(TerminalClipboardPolicy.selectionPasteboardName, "dev.leostera.axo.selection")
    XCTAssertEqual(TerminalClipboardPolicy.availableMIMETypes(hasPlainText: true), ["text/plain"])
    XCTAssertEqual(TerminalClipboardPolicy.availableMIMETypes(hasPlainText: false), [])
    XCTAssertNotNil(TerminalClipboardPolicy.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION))
  }
}
