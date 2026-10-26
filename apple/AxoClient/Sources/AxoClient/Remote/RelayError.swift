import Foundation

/// Why the relay refused or failed a request, as opposed to the host (`AxoClientError`).
public enum RelayError: Error, Equatable, LocalizedError {
  /// Cloudflare Access did not accept the caller: sign in again.
  case signInRequired
  /// The relay answered an HTTP request with a status other than success.
  case httpStatus(Int)

  public var errorDescription: String? {
    switch self {
    case .signInRequired: "Sign in with Cloudflare Access to continue."
    case .httpStatus(let status): "The Axo relay answered HTTP \(status)."
    }
  }
}
