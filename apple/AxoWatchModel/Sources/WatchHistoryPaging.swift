import AxoPhoneModel

/// Read only when the person scrolls back. A failed page must not become an automatic retry
/// loop; explicit retry is allowed, and a larger loaded window permits the next page.
public struct WatchHistoryPaging {
  private var requestedRecords: Int?
  private var automaticPages = 0

  public init() {}

  public mutating func begin(history: HostWorkbenchModel.HistoryState?, hasScrolled: Bool, nearTop: Bool, explicit: Bool = false) -> Bool {
    guard case .loaded(let records, true) = history else { return false }
    guard explicit || (hasScrolled && nearTop) else { return false }
    guard explicit || requestedRecords != records else { return false }
    // Tool-only pages may add no visible height. Bound that scan per gesture rather than
    // letting geometry callbacks download an entire large transcript in the background.
    guard explicit || automaticPages < 3 else { return false }
    if explicit { automaticPages = 0 } else { automaticPages += 1 }
    requestedRecords = records
    return true
  }

  public mutating func interactionBegan() { automaticPages = 0; requestedRecords = nil }

  public mutating func reset() { requestedRecords = nil; automaticPages = 0 }
}
