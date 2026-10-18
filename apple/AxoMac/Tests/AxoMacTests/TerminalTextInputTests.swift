import AppKit
import XCTest

@testable import AxoMac

@MainActor
final class TerminalTextInputTests: XCTestCase {
  func testCommittedTextDecodesSwiftAndAttributedStrings() throws {
    var decoder = TerminalCommittedText()

    XCTAssertEqual(decoder.decode("ordinary text"), "ordinary text")
    XCTAssertEqual(decoder.decode(NSAttributedString(string: "marked input")), "marked input")
  }

  func testCommittedTextCombinesSplitUnicodeSurrogatePair() throws {
    var decoder = TerminalCommittedText()
    let lead = try utf16CodeUnit(0xD83D)
    let trail = try utf16CodeUnit(0xDE00)

    XCTAssertEqual(decoder.decode(lead), "")
    XCTAssertEqual(decoder.decode(trail), "😀")
  }

  func testCommittedTextIgnoresStrayTrailAndClearsUnmatchedLead() throws {
    var decoder = TerminalCommittedText()
    let lead = try utf16CodeUnit(0xD83D)
    let trail = try utf16CodeUnit(0xDE00)

    XCTAssertNil(decoder.decode(trail))
    XCTAssertEqual(decoder.decode(lead), "")
    XCTAssertEqual(decoder.decode("next"), "next")
    XCTAssertNil(decoder.decode(trail))
  }

  func testCommittedTextRejectsUnsupportedValues() {
    var decoder = TerminalCommittedText()
    XCTAssertNil(decoder.decode(42))
  }

  func testIMEGeometryUsesCandidatePointAndCellSizeFallback() {
    let rect = TerminalIMEGeometry.viewRect(
      requestedRange: NSRange(location: 0, length: 1),
      selectionRange: NSRange(location: 0, length: 1),
      selectionTopLeft: nil,
      imePoint: CGRect(x: 14, y: 28, width: 0, height: 0),
      cellSize: CGSize(width: 8, height: 16),
      viewSize: CGSize(width: 400, height: 200)
    )

    XCTAssertEqual(rect, CGRect(x: 14, y: 172, width: 8, height: 16))
  }

  func testIMEGeometryUsesSelectionForQuickLookRange() {
    let rect = TerminalIMEGeometry.viewRect(
      requestedRange: NSRange(location: 50, length: 6),
      selectionRange: NSRange(location: 3, length: 4),
      selectionTopLeft: CGPoint(x: 40, y: 60),
      imePoint: CGRect(x: 14, y: 28, width: 8, height: 16),
      cellSize: CGSize(width: 8, height: 16),
      viewSize: CGSize(width: 400, height: 200)
    )

    XCTAssertEqual(rect, CGRect(x: 38, y: 138, width: 8, height: 16))
  }

  func testIMEGeometryPlacesDictationIndicatorAtRequestedOffset() {
    let rect = TerminalIMEGeometry.viewRect(
      requestedRange: NSRange(location: 2, length: 0),
      selectionRange: NSRange(location: 0, length: 0),
      selectionTopLeft: nil,
      imePoint: CGRect(x: 14, y: 28, width: 8, height: 12),
      cellSize: CGSize(width: 8, height: 16),
      viewSize: CGSize(width: 400, height: 200)
    )

    XCTAssertEqual(rect, CGRect(x: 30, y: 172, width: 0, height: 16))
  }

  private func utf16CodeUnit(_ value: UInt16) throws -> NSString {
    var value = value
    return withUnsafePointer(to: &value) { pointer in
      NSString(characters: pointer, length: 1)
    }
  }
}
