import Foundation

/// Why the relay refused or failed a request, as opposed to the host (`AxoClientError`).
public enum RelayError: Error, Equatable, LocalizedError {
  /// The relay did not accept the caller's session: sign in again.
  case signInRequired
  /// This device holds a session but cannot read it now, such as a locked iPhone's Keychain.
  /// Not a sign-out: the same session works once the device is unlocked.
  case credentialUnavailable
  /// The relay answered an HTTP request with a status other than success.
  case httpStatus(Int)
  /// The relay could not be reached (no network, a timeout); the system's reason says why.
  case unreachable(String)

  public var errorDescription: String? {
    switch self {
    case .signInRequired: "Sign in to continue."
    case .credentialUnavailable: "Unlock this device to continue."
    case .httpStatus(let status): "The Axo relay answered HTTP \(status)."
    case .unreachable(let reason): "Couldn't reach Axo: \(reason)"
    }
  }
}
