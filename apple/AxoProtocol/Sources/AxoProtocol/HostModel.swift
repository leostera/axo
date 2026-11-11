import Foundation

/// What kind of Mac a host is, as it reports itself (`HostModel` in `common.schema.json`): its
/// model identifier (`hw.model`, "Mac13,2") and, where macOS knows it, the model's name ("Mac
/// Studio", "MacBook Pro (14-inch, Nov 2024)").
public struct HostModel: Codable, Equatable, Hashable, Sendable {
  public let identifier: String
  public let name: String?

  public init(identifier: String, name: String? = nil) {
    self.identifier = identifier
    self.name = name
  }

  /// The shape of Mac it is, to show it by.
  public enum Family: String, Equatable, Sendable, CaseIterable {
    case laptop, studio, mini, desktop, tower
  }

  /// Read from the model's name, which says it ("Mac Studio"); a Mac without one (an Intel Mac)
  /// is read from its identifier ("Macmini8,1"), which says it only before Apple silicon. Nil
  /// when neither does; it shows as a Mac, as before. As on the web (`hostFamily`).
  public var family: Family? {
    if let name, let family = Self.family(name: name) { return family }
    return Self.family(identifier: identifier)
  }

  private static func family(name: String) -> Family? {
    if name.hasPrefix("MacBook") { return .laptop }
    if name.hasPrefix("Mac Studio") { return .studio }
    if name.hasPrefix("Mac mini") { return .mini }
    if name.hasPrefix("iMac") { return .desktop }
    if name.hasPrefix("Mac Pro") { return .tower }
    return nil
  }

  private static func family(identifier: String) -> Family? {
    if identifier.hasPrefix("MacBook") { return .laptop }
    if identifier.hasPrefix("Macmini") { return .mini }
    if identifier.hasPrefix("iMac") { return .desktop }
    if identifier.hasPrefix("MacPro") { return .tower }
    return nil
  }
}
