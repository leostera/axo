import Foundation

/// Axod's identifier for a Session: a UUID, the same on every surface (RFD0017). Distinct from
/// `ShellID` so the two can never be swapped.
///
/// Invariant: `rawValue` is the canonical lowercase hyphenated form, and the JSON encoding is
/// that string. Foundation's `UUID` encodes uppercase, so this type encodes its own string and
/// decoding rejects anything that is not canonical. IDs are assigned once and never reused, so code
/// that awaits may revalidate by looking the ID up again.
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: String

  /// Fails unless `rawValue` is a canonical lowercase UUID.
  public init?(rawValue: String) {
    guard Self.isCanonical(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  public init(_ uuid: UUID) {
    rawValue = uuid.uuidString.lowercased()
  }

  /// A new random Session ID.
  public static func random() -> SessionID { SessionID(UUID()) }

  public var uuid: UUID { UUID(uuidString: rawValue)! }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let id = SessionID(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Session IDs are canonical lowercase UUIDs")
    }
    self = id
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue }

  private static func isCanonical(_ value: String) -> Bool {
    let utf8 = Array(value.utf8)
    guard utf8.count == 36 else { return false }
    for (index, byte) in utf8.enumerated() {
      switch index {
      case 8, 13, 18, 23:
        guard byte == UInt8(ascii: "-") else { return false }
      default:
        guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        else { return false }
      }
    }
    return true
  }
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
