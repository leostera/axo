import Foundation

/// A short-lived code that authorizes linking one Axo host to an account.
public struct HostPairingCode: Equatable, Sendable {
  public let value: String

  public init?(parsing input: String) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count == 9 else { return nil }
    let normalized = trimmed.uppercased()
    let bytes = Array(normalized.utf8)
    guard bytes.count == 9, bytes[4] == 45,
      bytes[..<4].allSatisfy(Self.isCodeCharacter),
      bytes[5...].allSatisfy(Self.isCodeCharacter)
    else {
      return nil
    }
    value = normalized
  }

  /// Parses only the Axo pairing deep-link form; arbitrary URL parameters are rejected.
  public static func fromPairingURL(_ url: URL) -> HostPairingCode? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "axo",
      components.host?.lowercased() == "pair",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.fragment == nil,
      components.percentEncodedPath.first == "/"
    else {
      return nil
    }

    let path = String(components.percentEncodedPath.dropFirst())
    guard !path.contains("/"), !path.contains("%") else { return nil }
    return HostPairingCode(parsing: path)
  }

  private static func isCodeCharacter(_ byte: UInt8) -> Bool {
    (byte >= 48 && byte <= 57)
      || (byte >= 65 && byte <= 72)
      || (byte >= 74 && byte <= 75)
      || (byte >= 77 && byte <= 78)
      || (byte >= 80 && byte <= 84)
      || (byte >= 86 && byte <= 90)
  }
}
