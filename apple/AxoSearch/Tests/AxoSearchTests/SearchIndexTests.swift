import XCTest

import AxoSearch

final class SearchIndexTests: XCTestCase {
  private func titles(_ titles: [String], _ query: String) -> [String] {
    SearchIndex(titles) { SearchDocument(title: $0) }.search(SearchQuery(query)).map(\.item)
  }

  private func match(_ query: String, _ document: SearchDocument) -> SearchMatch? {
    SearchIndex([document]) { $0 }.search(SearchQuery(query)).first?.match
  }

  func testAnEmptyQueryReturnsEveryItemInTheGivenOrder() {
    XCTAssertEqual(titles(["b", "a", "c"], ""), ["b", "a", "c"])
    XCTAssertEqual(titles(["b", "a"], "  \t "), ["b", "a"])
    XCTAssertTrue(SearchQuery(" ").isEmpty)
  }

  func testCharactersMustAppearInOrderIgnoringCaseAndDiacritics() {
    XCTAssertEqual(titles(["Session", "Café Notes", "Notes"], "SESS"), ["Session"])
    XCTAssertEqual(titles(["Café"], "cafe"), ["Café"])
    XCTAssertEqual(titles(["cafe"], "CAFÉ"), ["cafe"])
    XCTAssertEqual(titles(["Session"], "ssee"), [])
    XCTAssertEqual(titles(["ab"], "abc"), [])
  }

  func testEveryTermMustMatchInAnyOrder() {
    XCTAssertEqual(titles(["deploy api", "deploy web", "api docs"], "api deploy"), ["deploy api"])
  }

  func testWordStartsAndRunsOutrankScatteredMatches() {
    XCTAssertEqual(titles(["transitions", "New Session"], "ns"), ["New Session", "transitions"])
    XCTAssertEqual(
      titles(["Super extra slow sync", "Session"], "sess"), ["Session", "Super extra slow sync"])
    XCTAssertEqual(titles(["foobar", "fooBar"], "b"), ["fooBar", "foobar"])
  }

  func testLongerGapsCostMore() throws {
    let short = try XCTUnwrap(match("ab", SearchDocument(title: "axb")))
    let long = try XCTUnwrap(match("ab", SearchDocument(title: "axxxxb")))
    XCTAssertGreaterThan(short.score, long.score)
  }

  func testHighlightsAreTheBestAlignmentNotTheFirst() throws {
    // Greedy matching would take a(0) b(1) c(5); the run at the end scores higher.
    let matched = try XCTUnwrap(match("abc", SearchDocument(title: "ab abc")))
    XCTAssertEqual(matched.titleHighlights, [3, 4, 5])
    XCTAssertEqual(try XCTUnwrap(match("ns", SearchDocument(title: "New Session"))).titleHighlights, [0, 4])
  }

  func testHighlightsAreCharacterOffsetsEvenAfterEmoji() throws {
    let matched = try XCTUnwrap(match("dep", SearchDocument(title: "🚀 Deploy")))
    XCTAssertEqual(matched.titleHighlights, [2, 3, 4])
  }

  func testHighlightsCountCharactersInsideTheMatchToo() throws {
    let matched = try XCTUnwrap(match("cafe", SearchDocument(title: "Café au lait")))
    XCTAssertEqual(matched.titleHighlights, [0, 1, 2, 3])
  }

  func testATermCountsWhereItMatchesBestNotWhereItMatchesFirst() throws {
    // "repo" is scattered mid-word in the title (about 0.48) but whole in the subtitle
    // (1.0, weighted to 0.5), so the subtitle wins and is what gets highlighted.
    let matched = try XCTUnwrap(
      match("repo", SearchDocument(title: "three deeps two", subtitle: "repo")))
    XCTAssertEqual(matched.subtitleHighlights, [0, 1, 2, 3])
    XCTAssertEqual(matched.titleHighlights, [])
  }

  func testEveryMatchingTermAddsToTheScore() throws {
    let document = SearchDocument(title: "deploy the api now")
    let both = try XCTUnwrap(match("deploy api", document)).score
    let deploy = try XCTUnwrap(match("deploy", document)).score
    let api = try XCTUnwrap(match("api", document)).score
    XCTAssertEqual(both, deploy + api, accuracy: 1e-9)
  }

  func testATitleMatchOutranksTheSameMatchInASubtitle() {
    // The subtitle match is on the shorter title, so only its lower weight puts it second.
    let documents = [
      SearchDocument(title: "Sh", subtitle: "api"),
      SearchDocument(title: "api docs", subtitle: "Shell"),
    ]
    let results = SearchIndex(documents) { $0 }.search(SearchQuery("api"))
    XCTAssertEqual(results.map(\.item.title), ["api docs", "Sh"])
    XCTAssertEqual(results[1].match.subtitleHighlights, [0, 1, 2])
    XCTAssertEqual(results[1].match.titleHighlights, [])
  }

  func testTermsCanMatchDifferentFields() throws {
    let matched = try XCTUnwrap(
      match("build api", SearchDocument(title: "build", subtitle: "api · ~/src/api")))
    XCTAssertEqual(matched.titleHighlights, [0, 1, 2, 3, 4])
    XCTAssertEqual(matched.subtitleHighlights, [0, 1, 2])
  }

  func testKeywordsFindAnItemWithoutHighlightingAnything() throws {
    let matched = try XCTUnwrap(
      match("pane", SearchDocument(title: "Pi", subtitle: "Session 3", keywords: ["pane"])))
    XCTAssertEqual(matched.titleHighlights, [])
    XCTAssertEqual(matched.subtitleHighlights, [])
    XCTAssertNil(match("pane", SearchDocument(title: "Pi", subtitle: "Session 3")))
    // Even when the title also matches, more weakly, a keyword match highlights nothing.
    let weak = try XCTUnwrap(
      match("pane", SearchDocument(title: "spray lunch knee", keywords: ["pane"])))
    XCTAssertEqual(weak.titleHighlights, [])
  }

  func testEqualScoresKeepTheShorterTitleThenTheGivenOrder() {
    XCTAssertEqual(titles(["api server", "api"], "api"), ["api", "api server"])
    XCTAssertEqual(titles(["api two", "api one"], "api"), ["api two", "api one"])
  }
}
