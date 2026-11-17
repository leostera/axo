import Foundation

/// These are distinct installed containers, not aliases or an automatic migration.
/// The explicit old-ID update target keeps the existing phone usable until migration is ready.
public enum PhoneStorageIdentity: String, Sendable {
  case canonical = "dev.leostera.axo"
  case existingPhone = "dev.leostera.axo.phone"

  public init?(bundleIdentifier: String?) {
    guard let bundleIdentifier else { return nil }
    self.init(rawValue: bundleIdentifier)
  }

  public var tokenService: String { rawValue + ".access" }
}
