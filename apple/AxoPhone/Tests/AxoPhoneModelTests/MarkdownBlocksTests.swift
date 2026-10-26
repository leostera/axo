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
      MarkdownBlocks.parse("```\n# not a heading\n- not a bullet\n| a | b |\n|---|---|\n> no\n---\n```"),
      [.code(language: nil, text: "# not a heading\n- not a bullet\n| a | b |\n|---|---|\n> no\n---")])
  }

  func testHeadings() {
    XCTAssertEqual(MarkdownBlocks.parse("# Title\n## Sub\n### Third\n#### Four"), [
      .heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .heading(level: 3, text: "Third"),
      .paragraph("#### Four"),
    ])
    XCTAssertEqual(MarkdownBlocks.parse("#nospace\n-nospace\n1.nospace"), [.paragraph("#nospace\n-nospace\n1.nospace")])
    XCTAssertEqual(MarkdownBlocks.parse("# \n- "), [.paragraph("# \n-")])
  }

  func testBulletsAndNumbersKeepTheirMarkerTheirNumberAndTheirDepth() {
    XCTAssertEqual(MarkdownBlocks.parse("- a\n* b\n+ c\n• d"), [
      .listItem(marker: .bullet, depth: 0, text: "a"), .listItem(marker: .bullet, depth: 0, text: "b"),
      .listItem(marker: .bullet, depth: 0, text: "c"), .listItem(marker: .bullet, depth: 0, text: "d"),
    ])
    XCTAssertEqual(MarkdownBlocks.parse("1. one\n2) two\n12. twelve"), [
      .listItem(marker: .number(1), depth: 0, text: "one"), .listItem(marker: .number(2), depth: 0, text: "two"),
      .listItem(marker: .number(12), depth: 0, text: "twelve"),
    ])
    XCTAssertEqual(MarkdownBlocks.parse("- top\n  - nested\n    1. deeper\n\t- tab"), [
      .listItem(marker: .bullet, depth: 0, text: "top"), .listItem(marker: .bullet, depth: 1, text: "nested"),
      .listItem(marker: .number(1), depth: 2, text: "deeper"), .listItem(marker: .bullet, depth: 2, text: "tab"),
    ])
  }

  func testQuotesJoinTheirLinesAndEndAtABlankLineOrProse() {
    XCTAssertEqual(MarkdownBlocks.parse("> one\n>two\n\n> three\nafter"), [
      .quote("one\ntwo"), .quote("three"), .paragraph("after"),
    ])
  }

  func testTablesNeedASeparatorAndEveryRowFitsTheHeader() {
    XCTAssertEqual(MarkdownBlocks.parse("| Name | Size |\n|:---|---:|\n| a | 1 |\n| b |\n| c | 3 | extra |\nafter"), [
      .table(header: ["Name", "Size"], rows: [["a", "1"], ["b", ""], ["c", "3"]]),
      .paragraph("after"),
    ])
    XCTAssertEqual(MarkdownBlocks.parse("a | b\n--|--\n1 | 2"), [.table(header: ["a", "b"], rows: [["1", "2"]])])
    XCTAssertEqual(MarkdownBlocks.parse("a | b\nnot a separator"), [.paragraph("a | b\nnot a separator")])
    XCTAssertEqual(MarkdownBlocks.parse("| a | b |\n|---|"), [.paragraph("| a | b |\n|---|")], "column counts must agree")
  }

  func testRules() {
    XCTAssertEqual(MarkdownBlocks.parse("above\n\n---\n* * *\n___\nbelow"), [
      .paragraph("above"), .rule, .rule, .rule, .paragraph("below"),
    ])
    XCTAssertEqual(MarkdownBlocks.parse("--"), [.paragraph("--")])
  }
}
