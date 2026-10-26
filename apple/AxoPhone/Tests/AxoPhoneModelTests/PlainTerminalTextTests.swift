import XCTest

@testable import AxoPhoneModel

final class PlainTerminalTextTests: XCTestCase {
  private func render(_ chunks: String...) -> String {
    var terminal = PlainTerminalText()
    for chunk in chunks { terminal.append(Data(chunk.utf8)) }
    return terminal.text
  }

  func testPlainTextAndNewlines() {
    XCTAssertEqual(render("hello\r\nworld\r\n"), "hello\nworld\n")
  }

  func testColoursAndCursorMovesAreDroppedNotPrinted() {
    XCTAssertEqual(render("\u{1B}[1;32mok\u{1B}[0m done\u{1B}[2K\u{1B}[3A"), "ok done")
  }

  func testWindowTitlesEndedByBellOrStringTerminatorAreDropped() {
    XCTAssertEqual(render("\u{1B}]0;title\u{07}a\u{1B}]2;other\u{1B}\\b"), "ab")
  }

  func testACarriageReturnRewritesTheLineFromItsStart() {
    XCTAssertEqual(render("loading 10%\rloading 90%"), "loading 90%")
    XCTAssertEqual(render("abcdef\rXY"), "XYcdef")
  }

  func testBackspaceOverwritesTheLastCharacter() {
    XCTAssertEqual(render("ab\u{08}c"), "ac")
  }

  func testSequencesSplitAcrossChunksAreStillDropped() {
    XCTAssertEqual(render("a\u{1B}", "[3", "1mb"), "ab")
    XCTAssertEqual(render("a\u{1B}]0;ti", "tle\u{07}b"), "ab")
  }

  func testACharacterSplitAcrossChunksIsAssembled() {
    let bytes = Array("é🦀".utf8)
    var terminal = PlainTerminalText()
    terminal.append(Data(bytes[0..<1]))
    XCTAssertEqual(terminal.text, "")
    terminal.append(Data(bytes[1..<4]))
    terminal.append(Data(bytes[4...]))
    XCTAssertEqual(terminal.text, "é🦀")
  }

  func testInvalidBytesBecomeReplacementCharactersAndNeverCrash() {
    var terminal = PlainTerminalText()
    terminal.append(Data([0xFF, 0x41, 0xC3, 0x28]))
    XCTAssertEqual(terminal.text, "\u{FFFD}A\u{FFFD}(")
  }

  func testOldLinesAreDroppedPastTheLimit() {
    var terminal = PlainTerminalText(maximumCharacters: 30)
    for number in 0..<20 { terminal.append(Data("line \(number)\n".utf8)) }
    XCTAssertTrue(terminal.text.count <= 40)
    XCTAssertTrue(terminal.text.hasSuffix("line 19\n"))
    XCTAssertFalse(terminal.text.contains("line 0\n"))
  }
}
