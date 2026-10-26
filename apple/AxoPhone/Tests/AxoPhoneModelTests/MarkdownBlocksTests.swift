import XCTest

@testable import AxoPhoneModel

final class MarkdownBlocksTests: XCTestCase {
  func testProseSplitsOnBlankLinesAndKeepsLineBreaksWithin() {
    XCTAssertEqual(
      MarkdownBlocks.parse("one\ntwo\n\nthree"), [.paragraph("one\ntwo"), .paragraph("three")])
    XCTAssertEqual(MarkdownBlocks.parse(""), [])
    XCTAssertEqual(MarkdownBlocks.parse("  \n\n "), [])
  }

  func testFencedCodeKeepsItsLinesAndNamesItsLanguage() {
    let blocks = MarkdownBlocks.parse("Run:\n```swift\nlet a = 1\n\n  let b = 2\n```\nDone.")
    XCTAssertEqual(blocks, [
      .paragraph("Run:"),
      .code(language: "swift", text: "let a = 1\n\n  let b = 2"),
      .paragraph("Done."),
    ])
    XCTAssertEqual(MarkdownBlocks.parse("```\nplain\n```"), [.code(language: nil, text: "plain")])
  }

  func testAnUnclosedFenceRunsToTheEndSoAnArrivingReplyKeepsItsCode() {
    XCTAssertEqual(
      MarkdownBlocks.parse("```sh\nls -la\ncd /"), [.code(language: "sh", text: "ls -la\ncd /")])
  }

  func testMarkersInsideCodeAreNotStructure() {
    XCTAssertEqual(
      MarkdownBlocks.parse("```\n# not a heading\n- not a bullet\n```"),
      [.code(language: nil, text: "# not a heading\n- not a bullet")])
  }

  func testHeadingsAndBullets() {
    XCTAssertEqual(MarkdownBlocks.parse("# Title\n## Sub\n### Third\n#### Four"), [
      .heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .heading(level: 3, text: "Third"),
      .paragraph("#### Four"),
    ])
    XCTAssertEqual(MarkdownBlocks.parse("- a\n* b\n• c\n1. d\n12. e"), [
      .bullet("a"), .bullet("b"), .bullet("c"), .bullet("d"), .bullet("e"),
    ])
    XCTAssertEqual(MarkdownBlocks.parse("#nospace\n-nospace\n1.nospace"), [.paragraph("#nospace\n-nospace\n1.nospace")])
    XCTAssertEqual(MarkdownBlocks.parse("# \n- "), [.paragraph("# \n-")])
  }
}
