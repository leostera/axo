import FuzzyMatch

/// Ranking for things a client already holds: Session and Workspace names, panes and commands.
/// Platform-neutral and free of UI, so every Axo client ranks the same way.
///
/// Matching itself is FuzzyMatch's Smith-Waterman mode (word-start, camelCase and acronym
/// bonuses, diacritic- and case-insensitive). This adds what a palette needs on top: items with
/// several fields, query terms that may each match a different field, and stable ordering.

/// What one item offers to search.
public struct SearchDocument: Equatable, Sendable {
  /// The primary text; matches here count fully and are highlighted.
  public var title: String
  /// Secondary text (a Workspace, a directory); matches count half and are highlighted.
  public var subtitle: String
  /// Hidden words that also find the item ("pane", "shell"); count half, never shown.
  public var keywords: [String]

  public init(title: String, subtitle: String = "", keywords: [String] = []) {
    self.title = title
    self.subtitle = subtitle
    self.keywords = keywords
  }
}

/// How well a document matched, and which of its characters did.
public struct SearchMatch: Equatable, Sendable {
  public let score: Double
  /// Character offsets into `SearchDocument.title`, ascending.
  public let titleHighlights: [Int]
  /// Character offsets into `SearchDocument.subtitle`, ascending.
  public let subtitleHighlights: [Int]

  public init(score: Double, titleHighlights: [Int] = [], subtitleHighlights: [Int] = []) {
    self.score = score
    self.titleHighlights = titleHighlights
    self.subtitleHighlights = subtitleHighlights
  }
}

/// A parsed query: whitespace-separated terms, all of which must match, each in any field.
public struct SearchQuery: Equatable, Sendable {
  let terms: [String]

  public init(_ text: String) {
    terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  public var isEmpty: Bool { terms.isEmpty }
}

public struct SearchResult<Item> {
  public let item: Item
  public let match: SearchMatch
}

extension SearchResult: Equatable where Item: Equatable {}
extension SearchResult: Sendable where Item: Sendable {}

/// Items to be searched repeatedly, as a palette does on every keystroke.
public struct SearchIndex<Item> {
  private let entries: [(item: Item, document: SearchDocument)]
  private let matcher = FuzzyMatcher(config: .smithWaterman)

  public init(_ items: [Item], document: (Item) -> SearchDocument) {
    entries = items.map { ($0, document($0)) }
  }

  /// Matching items, best first. Equal scores keep the shorter title first, then the order
  /// items were given in; an empty query returns every item in that order.
  public func search(_ query: SearchQuery) -> [SearchResult<Item>] {
    guard !query.isEmpty else {
      return entries.map { SearchResult(item: $0.item, match: SearchMatch(score: 0)) }
    }
    let terms = query.terms.map(matcher.prepare)
    var buffer = matcher.makeBuffer()
    var results: [(index: Int, titleLength: Int, result: SearchResult<Item>)] = []
    for (index, entry) in entries.enumerated() {
      guard let match = match(terms, in: entry.document, buffer: &buffer) else { continue }
      results.append(
        (index, entry.document.title.count, SearchResult(item: entry.item, match: match)))
    }
    results.sort { left, right in
      if left.result.match.score != right.result.match.score {
        return left.result.match.score > right.result.match.score
      }
      if left.titleLength != right.titleLength { return left.titleLength < right.titleLength }
      return left.index < right.index
    }
    return results.map(\.result)
  }

  private enum Field {
    case title
    case subtitle
    case keyword
  }

  /// Secondary fields weigh half, so a title match outranks the same match elsewhere.
  private static func weight(_ field: Field) -> Double {
    switch field {
    case .title: 1
    case .subtitle, .keyword: 0.5
    }
  }

  /// Every term must match some field and counts where it matches best.
  private func match(
    _ terms: [FuzzyQuery], in document: SearchDocument, buffer: inout ScoringBuffer
  ) -> SearchMatch? {
    var total = 0.0
    var titleHighlights = Set<Int>()
    var subtitleHighlights = Set<Int>()
    for term in terms {
      var best: (score: Double, field: Field)?
      func consider(_ text: String, _ field: Field) {
        guard !text.isEmpty,
          let scored = matcher.score(text, against: term, buffer: &buffer)
        else { return }
        let weighted = scored.score * Self.weight(field)
        if weighted > best?.score ?? 0 { best = (weighted, field) }
      }
      consider(document.title, .title)
      consider(document.subtitle, .subtitle)
      for keyword in document.keywords { consider(keyword, .keyword) }
      guard let best else { return nil }
      total += best.score
      switch best.field {
      case .title: titleHighlights.formUnion(highlights(of: term, in: document.title))
      case .subtitle: subtitleHighlights.formUnion(highlights(of: term, in: document.subtitle))
      case .keyword: break
      }
    }
    return SearchMatch(
      score: total,
      titleHighlights: titleHighlights.sorted(),
      subtitleHighlights: subtitleHighlights.sorted())
  }

  /// The matched characters as offsets, which a view can index without the original string.
  private func highlights(of term: FuzzyQuery, in text: String) -> [Int] {
    (matcher.highlight(text, against: term) ?? []).flatMap { range in
      let start = text.distance(from: text.startIndex, to: range.lowerBound)
      return start..<(start + text[range].count)
    }
  }
}
