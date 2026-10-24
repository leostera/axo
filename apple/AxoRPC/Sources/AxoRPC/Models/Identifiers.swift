import Foundation

/// Axod's identifier for a Session. Distinct from `ShellID` so the two can never be swapped; both
/// encode as plain JSON integers, matching the wire protocol.
///
/// Invariant: Axod allocates both with SQLite `INTEGER PRIMARY KEY AUTOINCREMENT`, so an ID is
/// never reused for a different Session or shell. Code that awaits may therefore revalidate by
/// looking the ID up again; no secondary identity (such as `sessionUuid`) is needed.
public struct SessionID: AxodIdentifier {
  public let rawValue: Int64
  public init(rawValue: Int64) { self.rawValue = rawValue }
}

/// Axod's identifier for one pane (shell/PTY) within a Session.
public struct ShellID: AxodIdentifier {
  public let rawValue: Int64
  public init(rawValue: Int64) { self.rawValue = rawValue }
}

public protocol AxodIdentifier: RawRepresentable, Hashable, Comparable, Codable, Sendable,
  CustomStringConvertible, ExpressibleByIntegerLiteral
where RawValue == Int64 {
  init(rawValue: Int64)
}

extension AxodIdentifier {
  public init?(rawValue: Int64) { self.init(rawValue: rawValue) }
  public init(integerLiteral value: Int64) { self.init(rawValue: value) }
  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(Int64.self))
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  public var description: String { String(rawValue) }
}
