import Foundation

protocol TerminalLayoutPersistence {
  func load() -> [Int64: TerminalLayout]
  func save(_ layouts: [Int64: TerminalLayout])
  func loadSelectedSessionID() -> Int64?
  func saveSelectedSessionID(_ sessionID: Int64?)
}

final class UserDefaultsTerminalLayoutPersistence: TerminalLayoutPersistence {
  private static let key = "terminalLayouts.v1"
  private static let selectedSessionKey = "terminalSelectedSession.v1"
  private static let maximumSnapshotBytes = 2 * 1024 * 1024

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> [Int64: TerminalLayout] {
    guard let data = defaults.data(forKey: Self.key),
      data.count <= Self.maximumSnapshotBytes,
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
      snapshot.version == 1,
      snapshot.records.allSatisfy({ $0.sessionID > 0 && $0.layout.isValidForPersistence }),
      Set(snapshot.records.map(\.sessionID)).count == snapshot.records.count
    else {
      return [:]
    }

    return Dictionary(
      uniqueKeysWithValues: snapshot.records.map { ($0.sessionID, $0.layout) }
    )
  }

  func save(_ layouts: [Int64: TerminalLayout]) {
    let records =
      layouts
      .sorted { $0.key < $1.key }
      .map { Snapshot.Record(sessionID: $0.key, layout: $0.value) }
    guard records.allSatisfy({ $0.sessionID > 0 && $0.layout.isValidForPersistence }),
      let data = try? JSONEncoder().encode(Snapshot(version: 1, records: records)),
      data.count <= Self.maximumSnapshotBytes
    else {
      return
    }
    defaults.set(data, forKey: Self.key)
  }

  func loadSelectedSessionID() -> Int64? {
    guard let sessionID = defaults.object(forKey: Self.selectedSessionKey) as? Int64,
      sessionID > 0
    else {
      return nil
    }
    return sessionID
  }

  func saveSelectedSessionID(_ sessionID: Int64?) {
    guard let sessionID, sessionID > 0 else {
      defaults.removeObject(forKey: Self.selectedSessionKey)
      return
    }
    defaults.set(sessionID, forKey: Self.selectedSessionKey)
  }
}

final class InMemoryTerminalLayoutPersistence: TerminalLayoutPersistence {
  private var layouts: [Int64: TerminalLayout] = [:]
  private var selectedSessionID: Int64?

  func load() -> [Int64: TerminalLayout] {
    layouts
  }

  func save(_ layouts: [Int64: TerminalLayout]) {
    self.layouts = layouts
  }

  func loadSelectedSessionID() -> Int64? {
    selectedSessionID
  }

  func saveSelectedSessionID(_ sessionID: Int64?) {
    selectedSessionID = sessionID
  }
}

private struct Snapshot: Codable {
  let version: Int
  let records: [Record]

  struct Record: Codable {
    let sessionID: Int64
    let layout: TerminalLayout
  }
}
