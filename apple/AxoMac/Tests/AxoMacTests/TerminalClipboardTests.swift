import AppKit
import Foundation
import GhosttyKit
import XCTest

@testable import AxoMac

final class TerminalClipboardTests: XCTestCase {
  func testConsentRequiresExplicitAllowAndRejectsDenyOrCancel() {
    XCTAssertTrue(TerminalClipboardConsent.isApproved(.alertSecondButtonReturn))
    XCTAssertFalse(TerminalClipboardConsent.isApproved(.alertFirstButtonReturn))
    XCTAssertFalse(TerminalClipboardConsent.isApproved(.cancel))
  }

  @MainActor
  func testConsentWithoutWindowIsDeniedImmediately() {
    var decision: Bool?
    TerminalClipboardConsent.requestAccess(
      for: GHOSTTY_CLIPBOARD_REQUEST_PASTE, text: "rm -rf ~", in: nil
    ) { decision = $0 }
    XCTAssertEqual(decision, false)
  }

  func testConsentAlertDefaultsToDenyAndRejectsUnknownRequests() throws {
    let alert = try XCTUnwrap(
      TerminalClipboardConsent.makeAlert(for: GHOSTTY_CLIPBOARD_REQUEST_PASTE, text: "x"))
    XCTAssertEqual(alert.buttons.map(\.title), ["Don't Allow", "Allow"])
    XCTAssertNotNil(alert.accessoryView, "users must see the exact text before allowing it")
    XCTAssertNil(
      TerminalClipboardConsent.makeAlert(for: ghostty_clipboard_request_e(rawValue: 999), text: ""))
  }

  func testClipboardWritesRequireExactlyOneValidPlainTextRepresentation() {
    XCTAssertNil(TerminalClipboardPolicy.singlePlainText(from: []))
    XCTAssertEqual(
      TerminalClipboardPolicy.singlePlainText(from: [
        TerminalClipboardContent(mimeType: "text/plain", data: Data("hello".utf8)),
      ]),
      "hello")
    XCTAssertNil(
      TerminalClipboardPolicy.singlePlainText(from: [
        TerminalClipboardContent(mimeType: "image/png", data: Data([1, 2, 3]))
      ]))
    XCTAssertNil(
      TerminalClipboardPolicy.singlePlainText(from: [
        TerminalClipboardContent(mimeType: "text/plain", data: Data("hello".utf8)),
        TerminalClipboardContent(mimeType: "image/png", data: Data([1, 2, 3])),
      ]))
    XCTAssertNil(
      TerminalClipboardPolicy.singlePlainText(from: [
        TerminalClipboardContent(mimeType: "text/plain", data: Data([0xff])),
      ]))
    XCTAssertNil(
      TerminalClipboardPolicy.singlePlainText(from: [
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
