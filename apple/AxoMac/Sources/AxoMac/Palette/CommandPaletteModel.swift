import AxoSearch
import Observation

/// One entry as the palette shows it: the item and how the query matched it.
struct CommandPaletteResult: Identifiable, Equatable {
  let item: CommandPaletteItem
  let match: SearchMatch
  var id: String { item.id }
}

/// The command palette's state: whether it is open, the query, its results and the selection.
///
/// Entries are a snapshot taken when the palette opens, searched on every keystroke; the
/// chosen action is revalidated by whoever performs it, as the catalog may have changed.
@MainActor
@Observable
final class CommandPaletteModel {
  private(set) var isPresented = false
  var query = "" {
    didSet {
      if query != oldValue { search() }
    }
  }
  private(set) var results: [CommandPaletteResult] = []
  private(set) var selectedIndex = 0
  @ObservationIgnored private var index = SearchIndex<CommandPaletteItem>([]) { $0.document }

  var selectedResult: CommandPaletteResult? {
    results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
  }

  func present(_ items: [CommandPaletteItem]) {
    index = SearchIndex(items) { $0.document }
    query = ""
    search()
    isPresented = true
  }

  func dismiss() {
    isPresented = false
  }

  /// Moves the selection by `offset`, wrapping around the ends.
  func moveSelection(by offset: Int) {
    guard !results.isEmpty else { return }
    let count = results.count
    selectedIndex = ((selectedIndex + offset) % count + count) % count
  }

  func select(_ resultID: CommandPaletteResult.ID) {
    if let index = results.firstIndex(where: { $0.id == resultID }) { selectedIndex = index }
  }

  /// Closes the palette and returns the selected entry's action, if there is one.
  func choose() -> CommandPaletteAction? {
    guard let action = selectedResult?.item.action else { return nil }
    dismiss()
    return action
  }

  /// Re-ranks for the current query and selects the best match.
  private func search() {
    results = index.search(SearchQuery(query)).map {
      CommandPaletteResult(item: $0.item, match: $0.match)
    }
    selectedIndex = 0
  }
}
